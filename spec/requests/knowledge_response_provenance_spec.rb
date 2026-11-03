require 'rails_helper'

RSpec.describe 'Signed response provenance' do
  self.use_transactional_tests = false

  let(:key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'Synthetic inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Synthetic customer') }
  let(:link) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: link) }
  let(:bot) { AgentBot.create!(name: 'Synthetic bot', outgoing_url: "https://processor.example/api/v1/a2a/#{root_id}") }
  let(:first) { conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'Quais opções?', created_at: 10.seconds.ago) }
  let(:grant) { grant_for(first) }
  let(:base) { KnowledgeBase.create!(account_scope: 'community', name: "Synthetic-#{root_id}") }
  let(:entry) do
    KnowledgeEntry.create!(account_scope: 'community', knowledge_base: base, title: 'Opções', body: 'Opção azul', content_type: 'faq',
                           status: 'published')
  end
  let(:proof) { response_proof(body, sources: sources) }
  let(:executor_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:root_id) { SecureRandom.uuid }

  def secret
    's' * 40
  end

  def body
    'A primeira opção é azul.'
  end

  def sources
    [{ id: entry.id, base_version: base.lock_version, body_sha256: Digest::SHA256.hexdigest(entry.body), updated_at: entry.updated_at.iso8601(6) }]
  end

  around do |example|
    values = settings
    previous = values.keys.index_with { |name| ENV.fetch(name, nil) }
    ENV.update(values)
    example.run
  ensure
    previous.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  before do
    allow(RuntimeConfig).to receive(:account).and_return(nil)
    resolver = instance_double(AgentBots::SessionSyncAgentResolver, call: root_id)
    allow(AgentBots::SessionSyncAgentResolver).to receive(:new).and_return(resolver)
    AgentBotInbox.create!(agent_bot: bot, inbox: inbox, status: :active)
    KnowledgeRuntime::BindingSet.replace!(account_scope: 'community', agent_id: root_id, base_ids: [base.id],
                                          expected_revision: 0, user_id: SecureRandom.uuid)
  end

  after { cleanup }

  def settings
    { 'KNOWLEDGE_RUNTIME_HISTORY_ENABLED' => 'true', 'KNOWLEDGE_RUNTIME_HISTORY_TOKEN' => secret,
      'KNOWLEDGE_RUNTIME_GRANTS_ENABLED' => 'true', 'KNOWLEDGE_RUNTIME_ACCOUNT_MODE' => 'community-single',
      'KNOWLEDGE_RUNTIME_ACCOUNT_SCOPE' => 'community', 'KNOWLEDGE_RUNTIME_GRANT_ISSUER' => 'crm',
      'KNOWLEDGE_RUNTIME_GRANT_AUDIENCE' => 'knowledge', 'KNOWLEDGE_RUNTIME_GRANT_KID' => 'test',
      'KNOWLEDGE_RUNTIME_GRANT_PRIVATE_KEY' => key.to_pem, 'KNOWLEDGE_RUNTIME_HISTORY_PUBLIC_KEYS' => '{}',
      'KNOWLEDGE_RESPONSE_PROVENANCE_ENABLED' => 'true', 'KNOWLEDGE_EXECUTOR_ISSUER' => 'processor',
      'KNOWLEDGE_EXECUTOR_PUBLIC_KEY' => executor_key.public_key.to_pem, 'BOT_RUNTIME_SECRET' => secret }
  end

  def grant_for(event)
    KnowledgeRuntime::GrantIssuer.issue(conversation_id: conversation.id, message_id: event.id, bot_id: bot.id, request_sha256: 'a' * 64)
  end

  def signed(token, audience, extra = {})
    now = Time.now.to_i
    claims = { iss: 'processor', aud: audience, iat: now, exp: now + 30, agent_id: root_id,
               config_sha256: 'a' * 64, grant: token, tool_categories: [], conversation_id: conversation.id,
               bot_id: bot.id, account_scope: 'community' }.merge(extra)
    if audience == 'knowledge-response'
      claims.delete(:grant)
      origin = JWT.decode(token, nil, false).first
      %w[inbox_id contact_id root_agent_id event_id request_sha256].each { |field| claims[field] = origin[field] }
    end
    JWT.encode(claims, executor_key, 'RS256')
  end

  def response_proof(content, extra = {})
    signed(grant, 'knowledge-response', { jti: SecureRandom.uuid, body_sha256: Digest::SHA256.hexdigest(content),
                                          profile_revision: 1, sources: [] }.merge(extra))
  end

  def deliver(token, content)
    KnowledgeRuntime::ResponseProvenance.record!(token: token, content: content, conversation: conversation, bot: bot) do
      conversation.messages.create!(inbox: inbox, message_type: :outgoing, content: content, status: :delivered, created_at: 8.seconds.ago)
    end
  end

  def read_history(token, executor_id = root_id)
    headers = { 'X-Knowledge-History-Token' => secret, 'X-Knowledge-Grant' => token,
                'X-Knowledge-Executor' => signed(token, 'knowledge-history-executor', agent_id: executor_id) }
    post '/internal/knowledge_runtime/history', headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    response.parsed_body['typed_turns']
  end

  it 'deduplicates volatile external results without authorizing their reuse' do
    token = response_proof(body, tool_categories: ['external_live_read'], reusable: false)
    delivered = deliver(token, body)
    expect(deliver(token, body).id).to eq(delivered.id)
    expect(KnowledgeResponseProvenance.find_by!(message_id: delivered.id)).not_to be_reusable
    event = conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'Consulte novamente', created_at: 2.seconds.ago)
    expect(read_history(grant_for(event)).none? { |turn| turn['text'] == body }).to be(true)
  end

  it 'rejects a reusable claim for external live results and nonboolean reuse flags' do
    [true, nil, 'false'].each do |value|
      token = response_proof(body, tool_categories: ['external_live_read'], reusable: value)
      expect { deliver(token, body) }.to raise_error(KnowledgeRuntime::ResponseProvenance::Denied)
    end
  end

  it 'stores exact delivered response once and rejects body changes' do
    delivered = deliver(proof, body)
    expect(deliver(proof, body).id).to eq(delivered.id)
    expect(KnowledgeResponseProvenance.where(message_id: delivered.id).count).to eq(1)
    expect { deliver(proof, 'Editado') }.to raise_error(KnowledgeRuntime::ResponseProvenance::Denied)
    delivered.delete
    expect(KnowledgeResponseProvenance.find_by!(proof_jti: JWT.decode(proof, nil, false).first['jti']).message_id).to be_nil
    expect { deliver(proof, body) }.to raise_error(KnowledgeRuntime::ResponseProvenance::Denied)
  end

  it 'allows late delivery without reuse authority, deduplicates retries, and rejects proofs older than 24 hours' do
    expired = response_proof(body, iat: Time.now.to_i - 50, exp: Time.now.to_i - 1)
    delivered = deliver(expired, body)
    expect(KnowledgeResponseProvenance.find_by!(message_id: delivered.id)).not_to be_reusable
    expect(deliver(expired, body).id).to eq(delivered.id)
    ancient = response_proof(body, iat: Time.now.to_i - 90_000, exp: Time.now.to_i - 89_950)
    expect { deliver(ancient, body) }.to raise_error(KnowledgeRuntime::ResponseProvenance::Denied)
  end

  it 'reuses only the same executor and revokes derived content when its source changes' do
    deliver(proof, body)
    event = conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'Quero a primeira', created_at: 2.seconds.ago)
    token = grant_for(event)
    expect(read_history(token)).to include('role' => 'assistant', 'text' => body)
    expect(read_history(token, SecureRandom.uuid).none? { |turn| turn['role'] == 'assistant' }).to be(true)
    entry.update!(body: 'Fonte alterada')
    expect(read_history(token).none? { |turn| turn['role'] == 'assistant' }).to be(true)
  end

  it 'invalidates edited history permanently while allowing delivery status updates' do
    delivered = deliver(proof, body)
    record = KnowledgeResponseProvenance.find_by!(message_id: delivered.id)
    delivered.update!(status: :read)
    expect(record.reload).to be_reusable
    ENV['KNOWLEDGE_RESPONSE_PROVENANCE_ENABLED'] = 'false'
    delivered.update!(content: 'Editado')
    delivered.update!(content: body)
    ENV['KNOWLEDGE_RESPONSE_PROVENANCE_ENABLED'] = 'true'
    expect(record.reload).not_to be_reusable
  end

  it 'excludes messages deleted through the real controller and revoked incoming text' do
    delivered = deliver(proof, body)
    user = User.create!(name: 'Synthetic operator', email: "provenance-#{SecureRandom.hex(5)}@example.test")
    controller = Api::V1::Conversations::MessagesController.new
    allow(Api::V1::Conversations::MessagesController).to receive(:new).and_return(controller)
    allow(controller).to receive(:authenticate_request!) { Current.user = user }
    allow(controller).to receive(:has_user_permission?).and_return(true)
    allow(controller).to receive(:authorize).and_return(true)
    delete "/api/v1/conversations/#{conversation.id}/messages/#{delivered.id}", as: :json
    expect(response).to have_http_status(:ok)
    expect(delivered.reload.content).to eq(body)
    expect(KnowledgeResponseProvenance.find_by!(message_id: delivered.id)).not_to be_reusable
    revoked = conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'Mensagem revogada', created_at: 5.seconds.ago)
    # Deliberately bypass callbacks to prove the read guard protects provider SQL updates.
    revoked.update_columns(content_attributes: { revoked_by_contact: true }) # rubocop:disable Rails/SkipsModelValidations
    event = conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'Continuar', created_at: 2.seconds.ago)
    history = read_history(grant_for(event))
    expect(history.none? { |turn| turn['text'] == body || turn['text'] == revoked.content }).to be(true)
  ensure
    Current.reset
    user&.delete
  end

  it 'serializes concurrent retries before creating the message' do
    token = proof
    start = Queue.new
    results = Queue.new
    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          results << deliver(token, body).id
        end
      end
    end
    2.times { start << true }
    threads.each(&:value)
    expect(Array.new(2) { results.pop }.uniq.size).to eq(1)
    expect(conversation.messages.where(content: body).count).to eq(1)
  end

  it 'delivers the signed postback through the real controller without duplicating its message' do
    conversation.update!(status: :pending)
    2.times do
      post "/webhooks/bot_runtime/postback/#{conversation.display_id}",
           params: { content: body, content_type: 'text', knowledge_provenance: proof },
           headers: { 'X-Bot-Runtime-Secret' => secret }, as: :json
      expect(response).to have_http_status(:ok)
    end
    expect(conversation.messages.where(content: body).count).to eq(1)
  end

  def cleanup
    KnowledgeResponseProvenance.where(executor_id: root_id).delete_all
    Message.where(conversation_id: conversation.id).delete_all
    conversation.delete
    cleanup_catalog_and_actors
  end

  def cleanup_catalog_and_actors
    KnowledgeAgentBinding.where(knowledge_base_id: base.id).delete_all
    KnowledgeAgentAccessProfile.where(account_scope: 'community', external_agent_id: root_id).delete_all
    entry.delete
    base.delete
    link.delete
    contact.delete
    AgentBotInbox.where(agent_bot_id: bot.id).delete_all
    bot.delete
    inbox.delete
    channel.delete
  end
end
