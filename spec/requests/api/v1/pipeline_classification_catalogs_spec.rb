require 'rails_helper'

RSpec.describe 'Pipeline classification catalog API', type: :request do
  let(:user) { User.create!(name: 'Pipeline owner', email: "catalog-#{SecureRandom.hex(5)}@example.test") }
  let!(:pipeline) { Pipeline.create!(name: "Catalog API #{SecureRandom.hex(5)}", created_by: user) }
  let!(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'Considering', position: 1) }
  let(:url) { "/api/v1/pipelines/#{pipeline.id}/classification_catalog" }
  let(:service_request) { false }
  let(:allowed_permissions) { %w[pipelines.read pipelines.update] }

  before do
    operator = user
    permissions = allowed_permissions
    allow(Api::V1::PipelineClassificationCatalogsController).to receive(:new).and_wrap_original do |original, *args|
      controller = original.call(*args)
      allow(controller).to receive(:authenticate_request!) do
        Current.user = service_request ? nil : operator
        Current.service_authenticated = true if service_request
      end
      allow(controller).to receive(:has_user_permission?) { |_user_id, permission| permissions.include?(permission) }
      controller
    end
    allow(user).to receive(:has_permission?) { |permission| permissions.include?(permission) }
    allow(user).to receive(:administrator?).and_return(false)
  end

  after { Current.reset }

  def body
    response.parsed_body
  end

  def payload
    profile = PipelineClassification::Catalog::DEFAULT_STAGE.deep_dup.merge(
      'classification_enabled' => true, 'definition' => 'Customer considers offers'
    )
    { classification: PipelineClassification::Catalog::DEFAULT_PROFILE.deep_dup.merge('purpose' => 'Determine customer journey'),
      stages: [{ id: stage.id, classification_profile: profile }],
      expected_hash: PipelineClassification::Catalog.new(pipeline.reload).hash }
  end

  it 'returns complete OFF defaults with an ETag and credential status without credentials' do
    get url
    expect(response).to have_http_status(:ok)
    expect(body.dig('data', 'classification', 'enabled')).to be(false)
    expect(body.dig('data', 'stages', 0, 'classification_profile', 'entry_criteria')).to eq([])
    expect(response.headers['ETag']).to eq(%("#{body.dig('data', 'draft_hash')}"))
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
    patch url, params: attrs, headers: { 'If-Match' => %("#{expected}") }, as: :json
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
    expect(body.dig('data', 'compiled', 'questions').keys).to eq(%w[pipeline_candidate stage_candidate])
    expect(stage.reload.classification_profile).to eq({})
  end

  # Keep the complete approval/race lifecycle and its observable side effects in one regression example.
  it 'publishes a reviewed OFF revision and exposes a readonly approved projection' do # rubocop:disable RSpec/MultipleExpectations
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
    let(:service_request) { false }
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

  context 'with installation configuration permission' do
    let(:allowed_permissions) { %w[pipelines.read pipelines.update installation_configs.manage] }

    it 'exposes and changes only the movement pause while preserving other installation settings' do # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
      allow(Ai::DecisionClient).to receive(:status).and_return(configured: true, provider: 'openrouter')
      InstallationConfig.create!(name: 'PIPELINE_CLASSIFICATION_SETTINGS',
                                 value: { 'online_enabled' => true, 'privacy_reviewed' => true, 'language_validated' => true,
                                          'billing_ceiling_verified' => true, 'max_attempt_cost_usd' => 0.01,
                                          'daily_usd' => 2.0, 'daily_conversations' => 100,
                                          'budget_timezone' => 'America/Sao_Paulo', 'retention_days' => 90,
                                          'automatic_moves_enabled' => false })
      get "#{url}/runtime"
      expect(response).to have_http_status(:ok)
      expect(body.dig('data', 'automatic_moves_enabled')).to be(false)
      expect(body.dig('data', 'provider_configured')).to be(true)
      expect(body.dig('data', 'online_authorized')).to be(true)
      patch "#{url}/runtime", params: { automatic_moves_enabled: true }, as: :json
      expect(response).to have_http_status(:ok)
      expect(InstallationConfig.find_by!(name: 'PIPELINE_CLASSIFICATION_SETTINGS').value).to include(
        'online_enabled' => true, 'daily_usd' => 2.0, 'automatic_moves_enabled' => true
      )
      InstallationConfig.create!(name: 'PIPELINE_CLASSIFICATION_PROVIDER_STATE',
                                 value: { 'consecutive_failures' => 1, 'open_until' => nil,
                                          'manual_reset_required' => true, 'last_reason' => 'provider_http_401' })
      get "#{url}/runtime"
      expect(body.dig('data', 'provider_circuit', 'manual_reset_required')).to be(true)
      post "#{url}/runtime/reset_provider", as: :json
      expect(response).to have_http_status(:ok)
      expect(body.dig('data', 'provider_circuit', 'manual_reset_required')).to be(false)
      patch "#{url}/runtime", params: { automatic_moves_enabled: 'yes' }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'requires bounded cost settings and all operator attestations before enabling online evaluation' do
      allow(Ai::DecisionClient).to receive(:status).and_return(configured: true, provider: 'openrouter')
      patch "#{url}/runtime", params: { online_enabled: true, privacy_reviewed: true }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['error']).to eq('online_authorization_and_budget_required')

      patch "#{url}/runtime", params: { online_enabled: true, privacy_reviewed: true, language_validated: true,
                                        billing_ceiling_verified: true, max_attempt_cost_usd: 0.1, daily_usd: 2,
                                        daily_conversations: 100, budget_timezone: 'America/Sao_Paulo', retention_days: 90 }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['error']).to eq('max_attempt_cost_usd_out_of_range')
    end

    it 'requires an authorized provider credential before enabling online evaluation' do
      allow(Ai::DecisionClient).to receive(:status).and_return(configured: false, provider: 'openrouter')
      patch "#{url}/runtime", params: { online_enabled: true, privacy_reviewed: true, language_validated: true,
                                        billing_ceiling_verified: true, max_attempt_cost_usd: 0.01, daily_usd: 2,
                                        daily_conversations: 100, budget_timezone: 'America/Sao_Paulo', retention_days: 90 }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(body['error']).to eq('provider_credential_required')
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
    allow(self).to receive(:service_request).and_return(true)
    patch url, params: payload, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(body['error']).to eq('human_operator_required')
  end

  it 'permits the existing authenticated CRM service read contract for projections only' do
    allow(self).to receive(:service_request).and_return(true)
    get "#{url}/projection"
    expect(response).to have_http_status(:ok)
    expect(body.dig('data', 'source')).to eq('legacy')
    expect(body.dig('data', 'available')).to be(false)
    get url
    expect(response).to have_http_status(:forbidden)
  end

  it 'backfills one bounded historical batch idempotently and returns only safe batch metadata' do
    channel = Channel::WebWidget.create!(website_url: 'https://backfill.example.test')
    inbox = Inbox.create!(name: 'Backfill', channel: channel, enable_auto_assignment: false)
    contact = Contact.create!(name: 'Historical customer', email: "history-#{SecureRandom.hex(5)}@example.test")
    binding = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(5))
    conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: binding, status: :pending)
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation)
    incoming = conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'Historical request text')
    profile = PipelineClassification::Catalog::DEFAULT_STAGE.deep_dup.merge(
      'classification_enabled' => true, 'definition' => 'Customer considers offers'
    )
    pipeline.update!(config: { 'classification' => PipelineClassification::Catalog::DEFAULT_PROFILE.deep_dup.merge(
      'enabled' => true, 'mode' => 'observe', 'purpose' => 'Determine customer journey', 'inbox_ids' => [inbox.id]
    ) })
    stage.update!(classification_profile: profile)
    PipelineClassification::Editor.new(pipeline: pipeline.reload,
                                       actor: user).publish!(expected_hash: PipelineClassification::Catalog.new(pipeline).hash)

    post "#{url}/backfill", params: { limit: 1 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(body.dig('data', 'scheduled')).to eq(1)
    expect(body.dig('data', 'done')).to be(true)
    expect(body.to_json).not_to include('Historical request text', incoming.id)
    post "#{url}/backfill", params: { limit: 1 }, as: :json
    expect(response).to have_http_status(:ok)
    expect(body.dig('data', 'scheduled')).to eq(0)
    expect(PipelineClassificationState.find_by!(pipeline: pipeline, conversation: conversation).due_at).to be_present
  end

  it 'returns safe decision metadata for monitoring without provider or conversation text' do
    PipelineClassificationResult.create!(pipeline: pipeline, generation: 1, revision: 1, catalog_hash: 'a' * 64,
                                         model: PipelineClassification::Catalog::MODEL, question_version: 'pipeline_stage_v1',
                                         status: 'abstained', reason: 'uncertain_answer',
                                         decision: { 'confidence' => 0.42, 'private_text' => 'sensitive message body', 'api_key' => 'secret' })
    get "#{url}/results", params: { limit: 5 }
    expect(response).to have_http_status(:ok)
    expect(body.dig('data', 0, 'decision')).to eq({ 'confidence' => 0.42 })
    expect(body.to_json).not_to include('sensitive message body', 'secret', 'private_text')
  end

  it 'paginates monitoring results with a stable opaque cursor' do
    rows = [3, 2, 1].map do |minutes_ago|
      PipelineClassificationResult.create!(pipeline: pipeline, generation: 1, revision: 1, catalog_hash: 'a' * 64,
                                           model: PipelineClassification::Catalog::MODEL,
                                           question_version: 'pipeline_stage_v1', status: 'abstained',
                                           reason: 'uncertain_answer',
                                           created_at: minutes_ago.minutes.ago, updated_at: minutes_ago.minutes.ago)
    end

    get "#{url}/results", params: { limit: 2 }
    expect(response).to have_http_status(:ok)
    expect(body['data'].map { |row| row['id'] }).to eq(rows.reverse.first(2).map(&:id))

    get "#{url}/results", params: { limit: 2, before_id: body.dig('data', -1, 'id') }
    expect(response).to have_http_status(:ok)
    expect(body['data'].map { |row| row['id'] }).to eq([rows.first.id])
  end

  it 'rejects a malformed results cursor' do
    get "#{url}/results", params: { before_id: 'not-a-uuid' }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to eq('invalid_results_cursor')
  end

  # Keep the complete approval/race lifecycle and its observable side effects in one regression example.
  it 'exposes independent legacy references for review without importing them or changing the catalog hash' do # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
    get url
    original_hash = body.dig('data', 'draft_hash')
    pipeline.update!(description: 'Previous human purpose')
    stage.update!(automation_rules: { 'description' => 'Previous human stage criteria', 'rules' => [] })
    get url
    reference = { 'pipeline_description' => 'Previous human purpose',
                  'stages' => [{ 'id' => stage.id, 'description' => 'Previous human stage criteria' }] }
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
