require 'rails_helper'

RSpec.describe 'Knowledge runtime grant transport' do
  let(:secret) { 's' * 40 }
  let(:body) { { display_id: 42, bot_id: SecureRandom.uuid, message_ids: [SecureRandom.uuid], request_sha256: 'a' * 64 } }

  around do |example|
    previous = ENV.to_h.slice('KNOWLEDGE_RUNTIME_DISPATCH_ENABLED', 'KNOWLEDGE_RUNTIME_DISPATCH_TOKEN')
    ENV['KNOWLEDGE_RUNTIME_DISPATCH_ENABLED'] = 'true'
    ENV['KNOWLEDGE_RUNTIME_DISPATCH_TOKEN'] = secret
    example.run
  ensure
    %w[KNOWLEDGE_RUNTIME_DISPATCH_ENABLED KNOWLEDGE_RUNTIME_DISPATCH_TOKEN].each { |key| ENV.delete(key) }
    ENV.update(previous)
  end

  it 'denies missing credential before issuing a grant' do
    expect(KnowledgeRuntime::GrantIssuer).not_to receive(:issue_for_dispatch)
    post '/internal/knowledge_runtime/grants', params: body, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'requires a digest and returns a non-cacheable grant for a dedicated credential' do
    allow(KnowledgeRuntime::GrantIssuer).to receive(:issue_for_dispatch).and_return('signed-grant')
    post '/internal/knowledge_runtime/grants', params: body, headers: { 'X-Knowledge-Dispatch-Token' => secret }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(response.parsed_body['grant']).to eq('signed-grant')
    post '/internal/knowledge_runtime/grants', params: body.merge(request_sha256: 'bad'),
                                               headers: { 'X-Knowledge-Dispatch-Token' => secret }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'resolves session IDs from a validated dispatch and rejects invalid dispatches' do
    post '/internal/knowledge_runtime/identity', params: body, as: :json
    expect(response).to have_http_status(:unauthorized)
    conversation_id = SecureRandom.uuid
    contact_id = SecureRandom.uuid
    identity = KnowledgeRuntime::DispatchIdentity::Identity.new(conversation_id: conversation_id)
    allow(KnowledgeRuntime::DispatchIdentity).to receive(:resolve).and_return(identity)
    allow(Conversation).to receive(:find).with(conversation_id).and_return(instance_double(Conversation, id: conversation_id, contact_id: contact_id))
    post '/internal/knowledge_runtime/identity', params: body, headers: { 'X-Knowledge-Dispatch-Token' => secret }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('conversation_id' => conversation_id, 'contact_id' => contact_id)
    expect(response.headers['Cache-Control']).to include('no-store')
    allow(KnowledgeRuntime::DispatchIdentity).to receive(:resolve).and_raise(KnowledgeRuntime::DispatchIdentity::Denied)
    post '/internal/knowledge_runtime/identity', params: body, headers: { 'X-Knowledge-Dispatch-Token' => secret }, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'resolves the persisted conversation and contact, rejecting a foreign message' do
    channel = Channel::Api.create!
    inbox = Inbox.create!(name: 'Synthetic', channel: channel)
    contact = Contact.create!(name: 'Synthetic')
    contact_inbox = ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8))
    conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    bot = AgentBot.create!(name: 'Synthetic', outgoing_url: 'https://processor.example/api/v1/a2a/11111111-1111-4111-8111-111111111111')
    AgentBotInbox.create!(agent_bot: bot, inbox: inbox, status: :active)
    message = conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'Olá')
    payload = { display_id: conversation.display_id, bot_id: bot.id, message_ids: [message.id] }
    post '/internal/knowledge_runtime/identity', params: payload, headers: { 'X-Knowledge-Dispatch-Token' => secret }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('conversation_id' => conversation.id, 'contact_id' => contact.id)
    post '/internal/knowledge_runtime/identity', params: payload.merge(message_ids: [SecureRandom.uuid]),
                                                 headers: { 'X-Knowledge-Dispatch-Token' => secret }, as: :json
    expect(response).to have_http_status(:forbidden)
  end
end
