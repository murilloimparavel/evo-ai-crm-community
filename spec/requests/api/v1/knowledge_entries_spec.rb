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
