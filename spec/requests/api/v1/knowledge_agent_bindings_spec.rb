require 'rails_helper'

RSpec.describe 'Knowledge agent bindings API', type: :request do
  let(:user) { User.create!(name: 'Operator', email: "bind-#{SecureRandom.hex(5)}@example.test") }
  let(:agent_id) { SecureRandom.uuid }
  let(:path) { "/api/v1/agents/#{agent_id}/knowledge_bases" }
  let(:base) { KnowledgeBase.create!(account_scope: 'community', name: 'Sales') }

  before do
    actor = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) { Current.user = actor } # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?).and_return(true) # rubocop:disable RSpec/AnyInstance
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('KNOWLEDGE_CORE_DEDICATED_ACCOUNT_SCOPE').and_return('community')
    allow(RuntimeConfig).to receive(:account).and_return(nil)
    allow(EvoAiCoreService).to receive(:get_agent).and_return({ 'id' => agent_id })
  end

  after { Current.reset }

  it 'reads and updates bindings with revision control' do
    get path
    expect(response.parsed_body['data']).to eq('revision' => 0, 'base_ids' => [])
    put path, params: { base_ids: [base.id], expected_revision: 0 }, as: :json
    expect(response).to have_http_status(:ok)
    get path
    expect(response.parsed_body['data']).to eq('revision' => 1, 'base_ids' => [base.id])
    put path, params: { base_ids: [], expected_revision: 0 }, as: :json
    expect(response).to have_http_status(:conflict)
    expect(KnowledgeAgentBinding.where(external_agent_id: agent_id).count).to eq(1)
  end

  it 'fails closed if the Core dedication attestation or account scope is absent' do
    allow(ENV).to receive(:[]).with('KNOWLEDGE_CORE_DEDICATED_ACCOUNT_SCOPE').and_return(nil)
    put path, params: { base_ids: [], expected_revision: 0 }, as: :json
    expect(response).to have_http_status(:service_unavailable)
    allow(ENV).to receive(:[]).with('KNOWLEDGE_CORE_DEDICATED_ACCOUNT_SCOPE').and_return('other')
    get path
    expect(response).to have_http_status(:service_unavailable)
    expect(EvoAiCoreService).not_to have_received(:get_agent)
  end

  it 'fails closed for extension, inaccessible agent and Core failure' do
    allow(EvoExtensionPoints).to receive(:impl_for).and_call_original
    allow(EvoExtensionPoints).to receive(:impl_for).with(:runtime_context_with_scope).and_return(-> {})
    get path
    expect(response).to have_http_status(:service_unavailable)
    allow(EvoExtensionPoints).to receive(:impl_for).and_call_original
    allow(EvoAiCoreService).to receive(:get_agent).and_return({ 'id' => SecureRandom.uuid })
    get path
    expect(response).to have_http_status(:not_found)
    allow(EvoAiCoreService).to receive(:get_agent).and_raise(StandardError)
    get path
    expect(response).to have_http_status(:service_unavailable)
  end

  it 'requires both permissions, a human actor, and same-scope bases' do
    foreign = KnowledgeBase.create!(account_scope: 'other', name: 'Private')
    put path, params: { base_ids: [foreign.id], expected_revision: 0 }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?) do |_, _, permission| # rubocop:disable RSpec/AnyInstance
      permission != 'ai_agents.update'
    end
    put path, params: { base_ids: [base.id], expected_revision: 0 }, as: :json
    expect(response).to have_http_status(:forbidden)
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do # rubocop:disable RSpec/AnyInstance
      Current.user = nil
      Current.service_authenticated = true
    end
    get path
    expect(response).to have_http_status(:forbidden)
  end
end
