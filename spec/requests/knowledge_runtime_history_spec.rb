# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Knowledge runtime customer history' do
  let(:key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:root_id) { SecureRandom.uuid }
  let(:secret) { 's' * 40 }
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'Synthetic inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Synthetic customer') }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:bot) { AgentBot.create!(name: 'Synthetic bot', outgoing_url: "https://processor.example/api/v1/a2a/#{root_id}") }

  around do |example|
    values = { 'KNOWLEDGE_RUNTIME_HISTORY_ENABLED' => 'true', 'KNOWLEDGE_RUNTIME_HISTORY_TOKEN' => secret,
               'KNOWLEDGE_RUNTIME_GRANTS_ENABLED' => 'true', 'KNOWLEDGE_RUNTIME_ACCOUNT_MODE' => 'community-single',
               'KNOWLEDGE_RUNTIME_ACCOUNT_SCOPE' => 'community', 'KNOWLEDGE_RUNTIME_GRANT_ISSUER' => 'crm',
               'KNOWLEDGE_RUNTIME_GRANT_AUDIENCE' => 'knowledge', 'KNOWLEDGE_RUNTIME_GRANT_KID' => 'test',
               'KNOWLEDGE_RUNTIME_GRANT_PRIVATE_KEY' => key.to_pem, 'KNOWLEDGE_RUNTIME_HISTORY_PUBLIC_KEYS' => '{}' }
    previous = values.keys.index_with { |name| ENV.fetch(name, nil) }
    ENV.update(values)
    example.run
  ensure
    previous.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  it 'returns only customer text up to the verified event and rejects a forged grant' do
    allow(RuntimeConfig).to receive(:account).and_return(nil)
    allow(AgentBots::SessionSyncAgentResolver).to receive(:new).and_return(instance_double(AgentBots::SessionSyncAgentResolver, call: root_id))
    AgentBotInbox.create!(agent_bot: bot, inbox: inbox, status: :active)
    conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'Primeira', created_at: 4.seconds.ago)
    conversation.messages.create!(inbox: inbox, message_type: :outgoing, content: 'Segredo', created_at: 3.seconds.ago)
    event = conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'Segunda', created_at: 2.seconds.ago)
    after_event = conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'Depois', created_at: 1.second.ago)
    grant = KnowledgeRuntime::GrantIssuer.issue(conversation_id: conversation.id, message_id: event.id,
                                                bot_id: bot.id, request_sha256: 'a' * 64)
    headers = { 'X-Knowledge-History-Token' => secret, 'X-Knowledge-Grant' => grant }
    post '/internal/knowledge_runtime/history', headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['turns']).to eq(%w[Primeira Segunda])
    expect(response.parsed_body['history_incomplete']).to be(true)
    post '/internal/knowledge_runtime/history', headers: headers.merge('X-Knowledge-Grant' => 'invalid'), as: :json
    expect(response).to have_http_status(:forbidden)
    post '/internal/knowledge_runtime/history', headers: headers.except('X-Knowledge-History-Token'), as: :json
    expect(response).to have_http_status(:unauthorized)
    # Deliberately bypass timestamps to exercise rejection of ambiguous source order.
    after_event.update_column(:created_at, event.created_at) # rubocop:disable Rails/SkipsModelValidations
    post '/internal/knowledge_runtime/history', headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'accepts a still-valid grant from an explicitly trusted previous public key' do
    allow(RuntimeConfig).to receive(:account).and_return(nil)
    allow(AgentBots::SessionSyncAgentResolver).to receive(:new).and_return(instance_double(AgentBots::SessionSyncAgentResolver, call: root_id))
    AgentBotInbox.create!(agent_bot: bot, inbox: inbox, status: :active)
    event = conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'Olá', created_at: 1.second.ago)
    old_key = OpenSSL::PKey::RSA.generate(2048)
    ENV['KNOWLEDGE_RUNTIME_GRANT_PRIVATE_KEY'] = old_key.to_pem
    ENV['KNOWLEDGE_RUNTIME_GRANT_KID'] = 'old'
    grant = KnowledgeRuntime::GrantIssuer.issue(conversation_id: conversation.id, message_id: event.id,
                                                bot_id: bot.id, request_sha256: 'a' * 64)
    ENV['KNOWLEDGE_RUNTIME_GRANT_PRIVATE_KEY'] = key.to_pem
    ENV['KNOWLEDGE_RUNTIME_GRANT_KID'] = 'test'
    ENV['KNOWLEDGE_RUNTIME_HISTORY_PUBLIC_KEYS'] = { 'old' => old_key.public_key.to_pem }.to_json
    headers = { 'X-Knowledge-History-Token' => secret, 'X-Knowledge-Grant' => grant }
    post '/internal/knowledge_runtime/history', headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['history_incomplete']).to be(false)
    ENV['KNOWLEDGE_RUNTIME_HISTORY_PUBLIC_KEYS'] = '{}'
    post '/internal/knowledge_runtime/history', headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
