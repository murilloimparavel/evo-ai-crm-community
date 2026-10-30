require 'rails_helper'

RSpec.describe 'Pipeline classification catalog API', type: :request do
  let(:user) { User.create!(name: 'Pipeline owner', email: "catalog-#{SecureRandom.hex(5)}@example.test") }
  let!(:pipeline) { Pipeline.create!(name: "Catalog API #{SecureRandom.hex(5)}", created_by: user) }
  let!(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'Considering', position: 1) }
  let(:url) { "/api/v1/pipelines/#{pipeline.id}/classification_catalog" }
  let(:allowed_permissions) { %w[pipelines.read pipelines.update] }

  before do
    operator = user
    permissions = allowed_permissions
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) { Current.user = operator }
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?) { |_instance, _user_id, permission| permissions.include?(permission) }
    allow_any_instance_of(User).to receive(:has_permission?) { |_instance, permission| permissions.include?(permission) }
    allow_any_instance_of(User).to receive(:administrator?).and_return(false)
  end
  after { Current.reset }

  def body
    JSON.parse(response.body)
  end

  def payload
    { classification: PipelineClassification::Catalog::DEFAULT_PROFILE.deep_dup.merge('purpose' => 'Determine customer journey'),
      stages: [{ id: stage.id, classification_profile: PipelineClassification::Catalog::DEFAULT_STAGE.deep_dup.merge('classification_enabled' => true, 'definition' => 'Customer considers offers') }],
      expected_hash: PipelineClassification::Catalog.new(pipeline.reload).hash }
  end

  it 'returns complete OFF defaults with an ETag and credential status without credentials' do
    get url
    expect(response).to have_http_status(:ok)
    expect(body.dig('data', 'classification', 'enabled')).to be(false)
    expect(body.dig('data', 'stages', 0, 'classification_profile', 'entry_criteria')).to eq([])
    expect(response.headers['ETag']).to eq(%Q("#{body.dig('data', 'draft_hash')}"))
    expect(body.dig('data', 'credential_status').keys).to contain_exactly('provider', 'configured')
    expect(body.to_json).not_to include('api_key', 'Authorization')
  end

  it 'saves a draft with expected hash and refuses a concurrent stale write with 409' do
    attrs = payload
    patch url, params: attrs, as: :json
    expect(response).to have_http_status(:ok)
    expect(body.dig('data', 'classification', 'purpose')).to eq('Determine customer journey')
    patch url, params: attrs, as: :json
    expect(response).to have_http_status(:conflict)
  end

  it 'accepts If-Match for edits and validates malformed profile with 422' do
    attrs = payload
    expected = attrs.delete(:expected_hash)
    patch url, params: attrs, headers: { 'If-Match' => %Q("#{expected}") }, as: :json
    expect(response).to have_http_status(:ok)
    attrs[:classification]['unknown_tool'] = 'execute'
    attrs[:expected_hash] = PipelineClassification::Catalog.new(pipeline.reload).hash
    patch url, params: attrs, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'previews offline without publishing, calling the provider, or writing profiles' do
    expect(Ai::DecisionClient).not_to receive(:for_pipeline)
    expect do
      post "#{url}/preview", params: payload, as: :json
    end.not_to change(PipelineClassificationCatalog, :count)
    expect(response).to have_http_status(:ok)
    expect(body.dig('data', 'compiled', 'questions').keys).to eq(['stage_candidate'])
    expect(stage.reload.classification_profile).to eq({})
  end

  it 'publishes a reviewed OFF revision and exposes a readonly approved projection' do
    patch url, params: payload, as: :json
    expected = body.dig('data', 'draft_hash')
    post "#{url}/publish", params: { expected_hash: expected }, as: :json
    expect(response).to have_http_status(:ok)
    expect(body.dig('data', 'catalog_version')).to eq(1)
    expect(body.dig('data', 'dirty')).to be(false)
    expect(body.dig('data', 'classification', 'enabled')).to be(false)
    get "#{url}/projection"
    expect(response).to have_http_status(:ok)
    expect(body.dig('data', 'available')).to be(true)
    expect(body.dig('data', 'catalog_hash')).to eq(expected)
    expect(body.dig('data', 'stages', 0, 'classification_profile', 'definition')).to eq('Customer considers offers')
  end

  context 'with card movement permission only' do
    let(:allowed_permissions) { %w[pipelines.read pipeline_items.update] }
    it 'permits reading but rejects saving, previewing and approving criteria' do
      get url
      expect(response).to have_http_status(:ok)
      patch url, params: payload, as: :json
      expect(response).to have_http_status(:forbidden)
      post "#{url}/preview", params: payload, as: :json
      expect(response).to have_http_status(:forbidden)
      post "#{url}/publish", params: { expected_hash: payload[:expected_hash] }, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  it 'does not expose another owners private pipeline even to a pipeline manager' do
    other = User.create!(name: 'Other', email: "other-#{SecureRandom.hex(5)}@example.test")
    pipeline.update!(created_by: other, visibility: :private)
    get url
    expect(response).to have_http_status(:not_found)
    patch url, params: payload, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'refuses runtime service tokens for writes' do
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = nil
      Current.service_authenticated = true
    end
    patch url, params: payload, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(body['error']).to eq('human_operator_required')
  end
  it 'permits the existing authenticated CRM service read contract for projections only' do
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = nil
      Current.service_authenticated = true
    end
    get "#{url}/projection"
    expect(response).to have_http_status(:ok)
    expect(body.dig('data', 'source')).to eq('legacy')
    expect(body.dig('data', 'available')).to be(false)
    get url
    expect(response).to have_http_status(:forbidden)
  end

  it 'exposes independent legacy references for review without importing them or changing the catalog hash' do
    get url
    original_hash = body.dig('data', 'draft_hash')
    pipeline.update!(description: 'Previous human purpose')
    stage.update!(automation_rules: { 'description' => 'Previous human stage criteria', 'rules' => [] })
    get url
    reference = { 'pipeline_description' => 'Previous human purpose', 'stages' => [{ 'id' => stage.id, 'description' => 'Previous human stage criteria' }] }
    expect(body.dig('data', 'legacy_reference')).to eq(reference)
    expect(body.dig('data', 'draft_hash')).to eq(original_hash)
    expect(body.dig('data', 'classification', 'purpose')).to eq('')
    expect(body.dig('data', 'stages', 0, 'classification_profile', 'definition')).to eq('')
    post "#{url}/preview", params: payload, as: :json
    expect(response).to have_http_status(:ok)
    expect(body.dig('data', 'legacy_reference')).to eq(reference)
    expect(body.dig('data', 'compiled').to_json).not_to include('Previous human purpose', 'Previous human stage criteria')
    expect(stage.reload.classification_profile).to eq({})
    patch url, params: payload, as: :json
    expect(response).to have_http_status(:ok)
    approved_hash = body.dig('data', 'draft_hash')
    post "#{url}/publish", params: { expected_hash: approved_hash }, as: :json
    expect(response).to have_http_status(:ok)
    expect(body.dig('data', 'legacy_reference')).to eq(reference)
    stage.update!(automation_rules: { 'description' => 'Updated legacy reference', 'rules' => [] })
    get url
    expect(body.dig('data', 'draft_hash')).to eq(approved_hash)
    expect(body.dig('data', 'dirty')).to be(false)
    expect(body.dig('data', 'legacy_reference', 'stages', 0, 'description')).to eq('Updated legacy reference')
    get "#{url}/projection"
    expect(body.fetch('data')).not_to have_key('legacy_reference')
    expect(body.fetch('data').to_json).not_to include('Previous human purpose', 'Updated legacy reference')
  end

end
