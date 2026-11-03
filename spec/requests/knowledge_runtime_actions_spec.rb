# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Authenticated knowledge runtime actions' do
  let(:key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:executor_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:root_id) { SecureRandom.uuid }
  let(:agent_id) { SecureRandom.uuid }
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'Synthetic actions', channel: channel) }
  let(:contact) { Contact.create!(name: 'Synthetic customer') }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:bot) { AgentBot.create!(name: 'Synthetic bot', outgoing_url: "https://processor.example/api/v1/a2a/#{root_id}") }
  let!(:assignment) { AgentBotInbox.create!(agent_bot: bot, inbox: inbox, status: :active) }
  let(:event) { conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'Synthetic request', created_at: 1.second.ago) }

  around do |example|
    values = { 'KNOWLEDGE_RUNTIME_ACTIONS_ENABLED' => 'true', 'KNOWLEDGE_RUNTIME_ACTIONS_TOKEN' => 's' * 40,
               'KNOWLEDGE_EXECUTOR_ISSUER' => 'processor', 'KNOWLEDGE_EXECUTOR_PUBLIC_KEY' => executor_key.public_key.to_pem,
               'KNOWLEDGE_RUNTIME_GRANTS_ENABLED' => 'true', 'KNOWLEDGE_RUNTIME_ACCOUNT_MODE' => 'community-single',
               'KNOWLEDGE_RUNTIME_ACCOUNT_SCOPE' => 'community', 'KNOWLEDGE_RUNTIME_GRANT_ISSUER' => 'crm',
               'KNOWLEDGE_RUNTIME_GRANT_AUDIENCE' => 'knowledge', 'KNOWLEDGE_RUNTIME_GRANT_KID' => 'test',
               'KNOWLEDGE_RUNTIME_GRANT_PRIVATE_KEY' => key.to_pem }
    previous = values.keys.index_with { |name| ENV.fetch(name, nil) }
    ENV.update(values)
    example.run
  ensure
    previous.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  before do
    allow(RuntimeConfig).to receive(:account).and_return(nil)
  end

  def credentials(body)
    token = KnowledgeRuntime::GrantIssuer.issue(conversation_id: conversation.id, message_id: event.id,
                                                bot_id: bot.id, request_sha256: 'a' * 64)
    grant = JWT.decode(token, nil, false).first
    claims = grant.slice(*KnowledgeRuntime::ActionProof::FIELDS).merge('iss' => 'processor', 'aud' => 'knowledge-action',
                                                                       'iat' => Time.now.to_i, 'exp' => Time.now.to_i + 20,
                                                                       'agent_id' => agent_id, 'action_id' => SecureRandom.uuid,
                                                                       'body_sha256' => Digest::SHA256.hexdigest(body))
    { 'CONTENT_TYPE' => 'application/json', 'X-Knowledge-Actions-Token' => 's' * 40, 'X-Knowledge-Grant' => token,
      'X-Knowledge-Executor' => JWT.encode(claims, executor_key, 'RS256') }
  end

  it 'applies the authenticated label action once and rejects body or assignment changes' do
    label = Label.create!(title: "synthetic-#{SecureRandom.hex(4)}", color: '#123456')
    body = { tool: 'labels', action: 'add', labels: [label.title] }.to_json
    headers = credentials(body)
    2.times { post '/internal/knowledge_runtime/actions', params: body, headers: headers }
    expect(response).to have_http_status(:ok)
    expect(conversation.reload.label_list).to include(label.title)
    expect(KnowledgeRuntimeAction.where(event_id: event.id).count).to eq(1)
    post '/internal/knowledge_runtime/actions', params: body.sub('add', 'remove'), headers: headers
    expect(response).to have_http_status(:forbidden)
    assignment.update!(status: :inactive)
    post '/internal/knowledge_runtime/actions', params: body, headers: headers
    expect(response).to have_http_status(:forbidden)
    expect(conversation.reload.label_list).to include(label.title)
  end

  it 'rejects an untrusted caller and a target field outside the signed schema' do
    body = { tool: 'handoff', team_id: SecureRandom.uuid, conversation_id: SecureRandom.uuid }.to_json
    headers = credentials(body)
    post '/internal/knowledge_runtime/actions', params: body, headers: headers.except('X-Knowledge-Actions-Token')
    expect(response).to have_http_status(:unauthorized)
    post '/internal/knowledge_runtime/actions', params: body, headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it 'assigns the configured human team and returns the terminal handoff signal' do
    team = Team.create!(name: "Synthetic team #{SecureRandom.hex(4)}")
    body = { tool: 'handoff', team_id: team.id }.to_json
    post '/internal/knowledge_runtime/actions', params: body, headers: credentials(body)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('status' => 'success', 'terminal_handoff' => true)
    expect(conversation.reload).to have_attributes(team_id: team.id, status: 'open')
  end

  it 'adds and moves the authenticated conversation using model callbacks and the exact stage' do
    owner = User.create!(name: 'Synthetic owner', email: "synthetic-#{SecureRandom.hex(4)}@example.invalid")
    pipeline = Pipeline.create!(name: "Synthetic pipeline #{SecureRandom.hex(4)}", created_by: owner)
    first = pipeline.pipeline_stages.create!(name: 'Quote', position: 1)
    second = pipeline.pipeline_stages.create!(name: 'Payment', position: 2)
    add = { tool: 'pipeline', action: 'add_to_pipeline', pipeline_id: pipeline.id, stage_id: first.id }.to_json
    post '/internal/knowledge_runtime/actions', params: add, headers: credentials(add)
    expect(response).to have_http_status(:ok)
    item = pipeline.pipeline_items.active.find_by!(conversation_id: conversation.id)
    expect(item.pipeline_stage_id).to eq(first.id)
    move = { tool: 'pipeline', action: 'move_to_stage', pipeline_id: pipeline.id, stage_id: second.id }.to_json
    post '/internal/knowledge_runtime/actions', params: move, headers: credentials(move)
    expect(response).to have_http_status(:ok)
    expect(item.reload.pipeline_stage_id).to eq(second.id)
    expect(item.stage_movements.count).to eq(2)
  end

  def pause_label_action(ready, release)
    allow(KnowledgeRuntime::Actions).to receive(:labels!).and_wrap_original do |original, *args|
      ready << true
      release.pop
      original.call(*args)
    end
  end

  def mutate_in_thread(headers, body, outcomes)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        outcomes << KnowledgeRuntime::Actions.call(token: headers['X-Knowledge-Grant'],
                                                   proof_token: headers['X-Knowledge-Executor'], body: body)
      rescue StandardError => e
        outcomes << e
      end
    end
  end

  def revoke_in_thread(assignment_id, pid)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        pid << connection.select_value('SELECT pg_backend_pid()')
        connection.execute("UPDATE agent_bot_inboxes SET status=1 WHERE id=#{connection.quote(assignment_id)}")
      end
    end
  end

  def wait_for_mutex(writer_pid)
    query = "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = #{Integer(writer_pid)} AND locktype = 'advisory' AND NOT granted)"
    Timeout.timeout(5) do
      sleep 0.01 until ActiveRecord::Base.connection.select_value(query)
    end
  end

  def cleanup_race_records(label)
    KnowledgeRuntimeAction.where(event_id: event.id).delete_all
    AgentBotInbox.where(inbox_id: inbox.id).delete_all
    conversation.destroy!
    contact_inbox.destroy!
    inbox.destroy!
    contact.destroy!
    bot.destroy!
    channel.destroy!
    label&.destroy!
  end

  context 'when assignment revocation races an action' do
    self.use_transactional_tests = false

    it 'serializes raw SQL revocation with the action and denies the next call' do
      label = Label.create!(title: "race-#{SecureRandom.hex(4)}", color: '#123456')
      body = { tool: 'labels', action: 'add', labels: [label.title] }.to_json
      headers = credentials(body)
      ready = Queue.new
      release = Queue.new
      pid = Queue.new
      outcomes = Queue.new
      pause_label_action(ready, release)
      mutation = mutate_in_thread(headers, body, outcomes)
      Timeout.timeout(5) { ready.pop }
      revocation = revoke_in_thread(assignment.id, pid)
      wait_for_mutex(Timeout.timeout(5) { pid.pop })
      release << true
      [mutation, revocation].each { |thread| expect(thread.join(5)).not_to be_nil }
      expect(outcomes.pop).to include('status' => 'success')
      expect(conversation.reload.label_list).to include(label.title)
      post '/internal/knowledge_runtime/actions', params: body, headers: headers
      expect(response).to have_http_status(:forbidden)
    ensure
      release << true if release
      [mutation, revocation].compact.each { |thread| thread.join(5) }
      cleanup_race_records(label)
    end
  end
end
