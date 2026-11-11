require 'rails_helper'

RSpec.describe 'Knowledge bases API', type: :request do
  let(:user) { User.create!(name: 'Operator', email: "base-#{SecureRandom.hex(5)}@example.test") }

  before do
    actor = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) { Current.user = actor } # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?).and_return(true) # rubocop:disable RSpec/AnyInstance
  end

  after { Current.reset }

  it 'creates, lists and updates a base with optimistic locking' do
    post '/api/v1/knowledge_bases', params: { knowledge_base: { name: 'Vendas', description: 'Regras' } }, as: :json
    expect(response).to have_http_status(:created)
    id = response.parsed_body.dig('data', 'id')
    expect(KnowledgeBase.where(account_scope: 'community', name: 'Geral', legacy_default: true).count).to eq(1)
    get '/api/v1/knowledge_bases'
    expect(response.parsed_body['data'].pluck('id')).to include(id)
    patch "/api/v1/knowledge_bases/#{id}", params: { knowledge_base: { name: 'Equipe vendas', lock_version: 0 } }, as: :json
    expect(response).to have_http_status(:ok)
    patch "/api/v1/knowledge_bases/#{id}", params: { knowledge_base: { name: 'Sobrescrita', lock_version: 0 } }, as: :json
    expect(response).to have_http_status(:conflict)
    expect(KnowledgeBase.find(id).name).to eq('Equipe vendas')
  end

  it 'does not expose another account or let service tokens manage bases' do
    foreign = KnowledgeBase.create!(name: 'Private', account_scope: 'other')
    get "/api/v1/knowledge_bases/#{foreign.id}"
    expect(response).to have_http_status(:not_found)
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do # rubocop:disable RSpec/AnyInstance
      Current.user = nil
      Current.service_authenticated = true
    end
    get '/api/v1/knowledge_bases'
    expect(response).to have_http_status(:forbidden)
  end

  it 'tests retrieval only inside the selected base and only for published entries' do
    target = KnowledgeBase.create!(account_scope: 'community', name: 'Alvo')
    other = KnowledgeBase.create!(account_scope: 'community', name: 'Outra')
    KnowledgeEntry.create!(account_scope: 'community', knowledge_base: target, title: 'Piscina visível', body: 'Piscina quente',
                           content_type: 'rule', status: 'published')
    KnowledgeEntry.create!(account_scope: 'community', knowledge_base: target, title: 'Piscina rascunho', body: 'Piscina fria', content_type: 'rule',
                           status: 'draft')
    KnowledgeEntry.create!(account_scope: 'community', knowledge_base: other, title: 'Piscina alheia', body: 'Piscina limpa', content_type: 'rule',
                           status: 'published')
    post "/api/v1/knowledge_bases/#{target.id}/test_retrieval", params: { query: 'piscina' }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['data'].pluck('title')).to eq(['Piscina visível'])
  end

  it 'refuses publishing restricted entries while the scoped runtime is unavailable' do
    target = KnowledgeBase.create!(account_scope: 'community', name: 'Restrita')
    entry = KnowledgeEntry.create!(account_scope: 'community', knowledge_base: target, title: 'Regra', body: 'Texto', content_type: 'rule',
                                   status: 'draft')
    allow_any_instance_of(User).to receive(:administrator?).and_return(true) # rubocop:disable RSpec/AnyInstance
    post "/api/v1/knowledge_entries/#{entry.id}/publish"
    expect(response).to have_http_status(:forbidden)
    expect(entry.reload.status).to eq('draft')
  end

  it 'rejects moving and publishing a draft to a restricted base in one request' do
    general = KnowledgeBase.create!(account_scope: 'community', name: 'Geral', legacy_default: true)
    restricted = KnowledgeBase.create!(account_scope: 'community', name: 'Restrita')
    entry = KnowledgeEntry.create!(account_scope: 'community', knowledge_base: general, title: 'Rule', body: 'Text', content_type: 'rule',
                                   status: 'draft', created_by_id: user.id)
    allow_any_instance_of(User).to receive(:administrator?).and_return(true) # rubocop:disable RSpec/AnyInstance
    patch "/api/v1/knowledge_entries/#{entry.id}", params: { ai_knowledge_entry: { knowledge_base_id: restricted.id, status: 'published' } },
                                                   as: :json
    expect(response).to have_http_status(:forbidden)
    expect(entry.reload.attributes.slice('knowledge_base_id', 'status')).to eq('knowledge_base_id' => general.id, 'status' => 'draft')
  end

  it 'requires publish permission for status changes through update' do
    general = KnowledgeBase.create!(account_scope: 'community', name: 'Geral', legacy_default: true)
    entry = KnowledgeEntry.create!(account_scope: 'community', knowledge_base: general, title: 'Rule', body: 'Text', content_type: 'rule',
                                   status: 'draft', created_by_id: user.id)
    allow_any_instance_of(User).to receive(:administrator?).and_return(true) # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?) do |_, _, permission| # rubocop:disable RSpec/AnyInstance
      permission != 'ai_knowledge.publish'
    end
    patch "/api/v1/knowledge_entries/#{entry.id}", params: { ai_knowledge_entry: { status: 'published' } }, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(entry.reload.status).to eq('draft')
  end

  it 'creates and reuses the default base for legacy article creation' do
    2.times do |index|
      post '/api/v1/knowledge_entries', params: { ai_knowledge_entry: { title: "Rule #{index}", body: 'Text', content_type: 'rule' } }, as: :json
      expect(response).to have_http_status(:created)
    end
    expect(KnowledgeBase.where(account_scope: 'community', legacy_default: true).count).to eq(1)
    expect(KnowledgeEntry.where(account_scope: 'community').pluck(:knowledge_base_id).uniq).to eq([KnowledgeBase.find_by!(account_scope: 'community',
                                                                                                                          legacy_default: true).id])
  end
end
