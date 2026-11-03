# frozen_string_literal: true

require 'rails_helper'

RSpec.describe KnowledgeRuntime::GrantIssuer do
  let(:key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:conversation_id) { '11111111-1111-4111-8111-111111111111' }
  let(:inbox_id) { '22222222-2222-4222-8222-222222222222' }
  let(:contact_id) { '66666666-6666-4666-8666-666666666666' }
  let(:message_id) { '33333333-3333-4333-8333-333333333333' }
  let(:bot_id) { '44444444-4444-4444-8444-444444444444' }
  let(:root_id) { '55555555-5555-4555-8555-555555555555' }
  let(:conversation) { double(id: conversation_id, inbox_id: inbox_id, contact_id: contact_id) }
  let(:message) { double(id: message_id, incoming?: true, private?: false, created_at: 10.seconds.ago) }
  let(:bot) { double(id: bot_id, outgoing_url: "https://processor.example/api/v1/a2a/#{root_id}", bot_config: { 'agent_id' => root_id }) }
  let(:assignment) { double(agent_bot_id: bot_id) }
  let(:relation) { double }
  let(:arguments) { { conversation_id: conversation_id, message_id: message_id, bot_id: bot_id } }

  around do |example|
    keys = %w[KNOWLEDGE_RUNTIME_GRANTS_ENABLED KNOWLEDGE_RUNTIME_GRANT_ISSUER KNOWLEDGE_RUNTIME_GRANT_AUDIENCE
              KNOWLEDGE_RUNTIME_GRANT_KID KNOWLEDGE_RUNTIME_GRANT_PRIVATE_KEY KNOWLEDGE_RUNTIME_ACCOUNT_MODE
              KNOWLEDGE_RUNTIME_ACCOUNT_SCOPE]
    previous = keys.index_with { |name| ENV.fetch(name, nil) }
    ENV.update('KNOWLEDGE_RUNTIME_GRANTS_ENABLED' => 'true', 'KNOWLEDGE_RUNTIME_GRANT_ISSUER' => 'crm',
               'KNOWLEDGE_RUNTIME_GRANT_AUDIENCE' => 'knowledge-retrieval', 'KNOWLEDGE_RUNTIME_GRANT_KID' => 'key-1',
               'KNOWLEDGE_RUNTIME_GRANT_PRIVATE_KEY' => key.to_pem, 'KNOWLEDGE_RUNTIME_ACCOUNT_MODE' => 'community-single',
               'KNOWLEDGE_RUNTIME_ACCOUNT_SCOPE' => 'account-1')
    example.run
  ensure
    previous.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  before do
    allow(RuntimeConfig).to receive(:account).and_return({ 'id' => 'account-1' })
    allow(EvoExtensionPoints).to receive(:impl_for).and_return(nil)
    allow(Conversation).to receive(:find_by).with(id: conversation_id).and_return(conversation)
    allow(Message).to receive(:find_by).with(id: message_id, conversation_id: conversation_id, inbox_id: inbox_id).and_return(message)
    allow(AgentBotInbox).to receive(:where).with(inbox_id: inbox_id, status: :active).and_return(relation)
    allow(relation).to receive(:limit).with(2).and_return(relation)
    allow(relation).to receive(:to_a).and_return([assignment])
    allow(AgentBot).to receive(:find_by).with(id: bot_id).and_return(bot)
    allow_any_instance_of(AgentBots::SessionSyncAgentResolver).to receive(:call).and_return(root_id)
  end

  it 'signs an event-bound, short-lived, single-scope grant' do
    token = described_class.issue(**arguments)
    claims, header = JWT.decode(token, key.public_key, true, algorithm: 'RS256', aud: 'knowledge-retrieval',
                                                             verify_aud: true, iss: 'crm', verify_iss: true)
    expect(header['kid']).to eq('key-1')
    expect(claims).to include('account_scope' => 'account-1', 'conversation_id' => conversation_id, 'inbox_id' => inbox_id,
                              'bot_id' => bot_id, 'root_agent_id' => root_id, 'event_id' => message_id, 'contact_id' => contact_id)
    expect(claims['exp'] - claims['iat']).to eq(60)
    expect { JWT.decode(token, OpenSSL::PKey::RSA.generate(2048).public_key, true, algorithm: 'RS256') }
      .to raise_error(JWT::VerificationError)
    expect { JWT.decode(token, key.public_key, true, algorithm: 'RS256', aud: 'other', verify_aud: true) }
      .to raise_error(JWT::InvalidAudError)
    expired = JWT.encode(claims.merge('exp' => Time.now.to_i - 1), key, 'RS256', kid: 'key-1')
    expect { JWT.decode(expired, key.public_key, true, algorithm: 'RS256') }.to raise_error(JWT::ExpiredSignature)
  end

  it 'denies conversations without a verified contact identity' do
    allow(conversation).to receive(:contact_id).and_return(nil)
    expect { described_class.issue(**arguments) }.to raise_error(described_class::Denied)
  end

  it 'denies unconfigured, mismatched or tenant-aware scopes' do
    ENV.delete('KNOWLEDGE_RUNTIME_ACCOUNT_MODE')
    expect { described_class.issue(**arguments) }.to raise_error(described_class::Denied)
    ENV['KNOWLEDGE_RUNTIME_ACCOUNT_MODE'] = 'community-single'
    ENV['KNOWLEDGE_RUNTIME_ACCOUNT_SCOPE'] = 'other-account'
    expect { described_class.issue(**arguments) }.to raise_error(described_class::Denied)
    ENV['KNOWLEDGE_RUNTIME_ACCOUNT_SCOPE'] = 'account-1'
    allow(EvoExtensionPoints).to receive(:impl_for).with(:runtime_context_current_id).and_return(-> { 'other-account' })
    expect { described_class.issue(**arguments) }.to raise_error(described_class::Denied)
  end

  it 'denies by default and when signing config is absent' do
    ENV.delete('KNOWLEDGE_RUNTIME_GRANTS_ENABLED')
    expect { described_class.issue(**arguments) }.to raise_error(described_class::Denied)
    ENV['KNOWLEDGE_RUNTIME_GRANTS_ENABLED'] = 'true'
    ENV.delete('KNOWLEDGE_RUNTIME_GRANT_PRIVATE_KEY')
    expect { described_class.issue(**arguments) }.to raise_error(described_class::Denied)
  end

  it 'denies a foreign, private or non-incoming event' do
    [nil, double(incoming?: false, private?: false), double(incoming?: true, private?: true)].each do |event|
      allow(Message).to receive(:find_by).and_return(event)
      expect { described_class.issue(**arguments) }.to raise_error(described_class::Denied)
    end
  end

  it 'denies missing, ambiguous or mismatched active bot assignments' do
    [[], [assignment, assignment], [double(agent_bot_id: SecureRandom.uuid)]].each do |records|
      allow(relation).to receive(:to_a).and_return(records)
      expect { described_class.issue(**arguments) }.to raise_error(described_class::Denied)
    end
  end

  it 'denies disagreement between URL, configured root and resolver' do
    allow(bot).to receive(:bot_config).and_return({ 'agent_id' => SecureRandom.uuid })
    expect { described_class.issue(**arguments) }.to raise_error(described_class::Denied)
    allow(bot).to receive(:bot_config).and_return({ 'agent_id' => root_id })
    allow_any_instance_of(AgentBots::SessionSyncAgentResolver).to receive(:call).and_return(SecureRandom.uuid)
    expect { described_class.issue(**arguments) }.to raise_error(described_class::Denied)
  end

  it 'uses the database-resolved conversation UUID for dispatch grants' do
    identity = KnowledgeRuntime::DispatchIdentity::Identity.new(conversation_id: conversation_id, bot_id: bot_id,
                                                                message_ids: [message_id])
    expect(KnowledgeRuntime::DispatchIdentity).to receive(:resolve)
      .with(display_id: 42, message_ids: [message_id], bot_id: bot_id).and_return(identity)
    token = described_class.issue_for_dispatch(display_id: 42, message_ids: [message_id], bot_id: bot_id)
    claims, = JWT.decode(token, key.public_key, true, algorithm: 'RS256')
    expect(claims['conversation_id']).to eq(conversation_id)
  end

  it 'denies grant issuance if the dispatch identity is invalid' do
    allow(KnowledgeRuntime::DispatchIdentity).to receive(:resolve).and_raise(KnowledgeRuntime::DispatchIdentity::Denied)
    expect { described_class.issue_for_dispatch(display_id: 42, message_ids: [message_id], bot_id: bot_id) }
      .to raise_error(described_class::Denied)
  end

  it 'signs only a well-formed request digest when supplied' do
    digest = 'a' * 64
    token = described_class.issue(**arguments, request_sha256: digest)
    claims, = JWT.decode(token, key.public_key, true, algorithm: 'RS256')
    expect(claims['request_sha256']).to eq(digest)
    ['garbage', 'A' * 64, 7].each do |invalid|
      expect { described_class.issue(**arguments, request_sha256: invalid) }.to raise_error(described_class::Denied)
    end
  end

  it 'denies stale and future events' do
    allow(message).to receive(:created_at).and_return(6.minutes.ago)
    expect { described_class.issue(**arguments) }.to raise_error(described_class::Denied)
    allow(message).to receive(:created_at).and_return(1.minute.from_now)
    expect { described_class.issue(**arguments) }.to raise_error(described_class::Denied)
  end
end
