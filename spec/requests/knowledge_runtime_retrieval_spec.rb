# frozen_string_literal: true

require 'rails_helper'
require 'jwt'

RSpec.describe 'Internal knowledge retrieval' do
  let(:key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:agent_id) { SecureRandom.uuid }
  let(:now) { Time.now.to_i }
  let(:grant) do
    { 'account_scope' => 'scope-a', 'conversation_id' => SecureRandom.uuid, 'root_agent_id' => SecureRandom.uuid,
      'event_id' => SecureRandom.uuid, 'exp' => now + 60 }
  end
  let(:body) { '{"query":"piscina","limit":5}' }

  around do |example|
    vars = %w[KNOWLEDGE_RUNTIME_RETRIEVAL_ENABLED KNOWLEDGE_RUNTIME_RETRIEVAL_TOKEN KNOWLEDGE_EXECUTOR_PUBLIC_KEY KNOWLEDGE_EXECUTOR_ISSUER]
    previous = vars.index_with { |name| ENV.fetch(name, nil) }
    ENV.update('KNOWLEDGE_RUNTIME_RETRIEVAL_ENABLED' => 'true', 'KNOWLEDGE_RUNTIME_RETRIEVAL_TOKEN' => 'a' * 32,
               'KNOWLEDGE_EXECUTOR_PUBLIC_KEY' => key.public_key.to_pem, 'KNOWLEDGE_EXECUTOR_ISSUER' => 'processor')
    example.run
  ensure
    previous.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  def proof(body_text, agent = agent_id)
    claims = grant.merge('iss' => 'processor', 'aud' => 'knowledge-retrieval', 'iat' => now, 'exp' => now + 20,
                         'agent_id' => agent, 'body_sha256' => Digest::SHA256.hexdigest(body_text))
    JWT.encode(claims, key, 'RS256')
  end

  def headers(token)
    { 'CONTENT_TYPE' => 'application/json', 'X-Knowledge-Retrieval-Token' => 'a' * 32,
      'X-Knowledge-Grant' => 'dispatch', 'X-Knowledge-Executor' => token }
  end

  it 'requires a valid body-bound proof and rechecks bindings on each query' do
    allow(KnowledgeRuntime::CustomerHistory).to receive(:verified_claims).with('dispatch').and_return(grant)
    base = KnowledgeBase.create!(account_scope: 'scope-a', name: 'A')
    KnowledgeEntry.create!(account_scope: 'scope-a', knowledge_base: base, title: 'Piscina', body: 'Piscina aquecida',
                           content_type: 'faq', status: 'published')
    binding = KnowledgeAgentBinding.create!(account_scope: 'scope-a', knowledge_base: base, external_agent_id: agent_id, enabled: true)
    token = proof(body)
    post '/internal/knowledge_runtime/retrieve', params: body, headers: headers(token)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('results').length).to eq(1)
    binding.update!(enabled: false)
    post '/internal/knowledge_runtime/retrieve', params: body, headers: headers(token)
    expect(response.parsed_body.fetch('results')).to be_empty
    post '/internal/knowledge_runtime/retrieve', params: '{"query":"outra"}', headers: headers(token)
    expect(response).to have_http_status(:forbidden)
    bad_key = OpenSSL::PKey::RSA.generate(2048)
    forged = JWT.encode(JWT.decode(token, nil, false).first, bad_key, 'RS256')
    post '/internal/knowledge_runtime/retrieve', params: body, headers: headers(forged)
    expect(response).to have_http_status(:forbidden)
  end
end
