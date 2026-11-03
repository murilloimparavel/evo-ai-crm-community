# Separate credential modes deliberately exercise the public legacy boundary.
# rubocop:disable RSpec/MultipleDescribes
require 'rails_helper'

RSpec.describe 'Knowledge entries API', type: :request do
  let(:headers) { { 'X-Service-Token' => 'knowledge-spec-token' } }

  around do |example|
    previous = ENV.fetch('EVOAI_CRM_API_TOKEN', nil)
    ENV['EVOAI_CRM_API_TOKEN'] = 'knowledge-spec-token'
    example.run
  ensure
    ENV['EVOAI_CRM_API_TOKEN'] = previous
    Current.reset
  end

  it 'rejects published search without a conversation identifier' do
    get '/api/v1/knowledge_entries/search', params: { q: 'endereço' }, headers: headers
    expect(response).to have_http_status(:bad_request)
  end

  it 'rejects a conversation identifier that is not in this CRM' do
    get '/api/v1/knowledge_entries/search', params: { q: 'endereço', conversation_id: SecureRandom.uuid }, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it 'does not permit service credentials to publish knowledge' do
    entry = KnowledgeEntry.create!(title: 'Endereço', body: 'Rua A', content_type: 'company', account_scope: 'community')
    post "/api/v1/knowledge_entries/#{entry.id}/publish", headers: headers
    expect(response).to have_http_status(:forbidden)
    expect(entry.reload.status).to eq('draft')
  end
end

RSpec.describe 'Knowledge legacy isolation', type: :request do
  around do |example|
    previous = ENV.fetch('EVOAI_CRM_API_TOKEN', nil)
    ENV['EVOAI_CRM_API_TOKEN'] = 'knowledge-spec-token'
    example.run
  ensure
    ENV['EVOAI_CRM_API_TOKEN'] = previous
    Current.reset
  end

  it 'returns only published articles from the active default base' do
    general = KnowledgeBase.create!(account_scope: 'community', name: 'Geral', legacy_default: true)
    restricted = KnowledgeBase.create!(account_scope: 'community', name: 'Restrita')
    KnowledgeEntry.create!(account_scope: 'community', knowledge_base: general, title: 'Piscina pública', body: 'Piscina aquecida',
                           content_type: 'rule', status: 'published')
    KnowledgeEntry.create!(account_scope: 'community', knowledge_base: restricted, title: 'Piscina restrita', body: 'Piscina exclusiva',
                           content_type: 'rule', status: 'published')
    allow(Conversation).to receive(:exists?).and_return(true)
    get '/api/v1/knowledge_entries/search', params: { q: 'piscina', conversation_id: SecureRandom.uuid },
                                            headers: { 'X-Service-Token' => 'knowledge-spec-token' }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['data'].pluck('title')).to eq(['Piscina pública'])
  end
end

# rubocop:enable RSpec/MultipleDescribes
