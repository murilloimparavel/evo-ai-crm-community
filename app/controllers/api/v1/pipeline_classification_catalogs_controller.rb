class Api::V1::PipelineClassificationCatalogsController < Api::V1::BaseController
  wrap_parameters false
  require_permissions({ show: 'pipelines.read', results: 'pipelines.read', projection: 'pipelines.read',
                        backfill: 'pipelines.update', update: 'pipelines.update', preview: 'pipelines.update',
                        publish: 'pipelines.update', runtime_settings: 'installation_configs.manage',
                        update_runtime_settings: 'installation_configs.manage', reset_provider: 'installation_configs.manage' })
  before_action :human_operator!, except: [:projection]
  before_action :load_pipeline!

  def show
    authorize @pipeline, :show?
    render_catalog
  end

  def update
    authorize @pipeline, :update?
    PipelineClassification::Editor.new(pipeline: @pipeline, actor: Current.user).save!(payload: catalog_payload, expected_hash: expected_hash)
    render_catalog
  rescue PipelineClassification::Catalog::Conflict => e
    render json: { error: e.message }, status: :conflict
  rescue PipelineClassification::Catalog::Invalid, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def preview
    authorize @pipeline, :update?
    preview = PipelineClassification::Editor.new(pipeline: @pipeline, actor: Current.user).preview!(payload: catalog_payload)
    success_response(data: preview)
  rescue PipelineClassification::Catalog::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def publish
    authorize @pipeline, :update?
    PipelineClassification::Editor.new(pipeline: @pipeline, actor: Current.user).publish!(expected_hash: expected_hash)
    render_catalog
  rescue PipelineClassification::Catalog::Conflict => e
    render json: { error: e.message }, status: :conflict
  rescue PipelineClassification::Catalog::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def projection
    # Agent access to a pipeline remains independently authorized by its existing
    # pipeline_rules; this endpoint supplies only the approved semantic projection.
    # CRM service-token authentication already grants read access to pipeline
    # records. The processor scopes this projection against agent pipeline_rules;
    # this Rails database does not contain the remote agent authorization model.
    authorize @pipeline, :show? unless service_authenticated?
    catalog = PipelineClassification::Catalog.new(@pipeline)
    revision = catalog.published
    if revision.nil? || !catalog.current?
      return success_response(data: { pipeline_id: @pipeline.id, source: revision ? 'catalog_v1' : 'legacy', available: false })
    end

    response.headers['ETag'] = %("#{revision.catalog_hash}")
    success_response(data: { pipeline_id: @pipeline.id, source: 'catalog_v1', available: true,
                             catalog_version: revision.catalog_version, catalog_hash: revision.catalog_hash,
                             purpose: revision.snapshot.dig('classification', 'purpose'), stages: revision.snapshot.fetch('stages') })
  end

  # A privacy-limited operations view: decision metadata and card references only,
  # never message text, contact details, prompt inputs, or provider payloads.
  def results
    authorize @pipeline, :show?
    scope = PipelineClassificationResult.where(pipeline_id: @pipeline.id).order(created_at: :desc, id: :desc)
    if params[:before_id].present?
      valid_cursor = params[:before_id].match?(/\A[0-9a-f-]{36}\z/i)
      raise PipelineClassification::Catalog::Invalid, 'invalid_results_cursor' unless valid_cursor

      cursor = scope.find_by(id: params[:before_id])
      raise PipelineClassification::Catalog::Invalid, 'invalid_results_cursor' unless cursor

      scope = scope.where('created_at < :created_at OR (created_at = :created_at AND id < :id)',
                          created_at: cursor.created_at, id: cursor.id)
    end
    rows = scope.limit(params[:limit].presence&.to_i&.clamp(1, 100) || 50)
    success_response(data: rows.map { |row| result_data(row) })
  rescue PipelineClassification::Catalog::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # One request schedules at most 100 existing cards. Continue with next_cursor;
  # the scheduler applies the normal debounce, budget and online-authorization gates.
  def backfill # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    authorize @pipeline, :update?
    raise PipelineClassification::Catalog::Invalid, 'catalog_not_active' unless PipelineClassification::Lifecycle.active_catalog(@pipeline)

    limit = params[:limit].presence&.to_i || 50
    raise PipelineClassification::Catalog::Invalid, 'invalid_batch_limit' unless (1..100).cover?(limit)

    cursor = params[:after_id]
    raise PipelineClassification::Catalog::Invalid, 'invalid_cursor' if cursor.present? && !cursor.match?(/\A[0-9a-f-]{36}\z/i)

    scope = PipelineItem.active.where(pipeline_id: @pipeline.id).where.not(conversation_id: nil)
    scope = scope.where('pipeline_items.id > ?', cursor) if cursor.present?
    rows = scope.order(:id).limit(limit + 1).to_a
    has_more = rows.size > limit
    rows = rows.first(limit)
    scheduled = rows.count do |item|
      conversation = item.conversation
      conversation && PipelineClassification::Lifecycle.backfill!(pipeline: @pipeline, conversation: conversation)
    end
    success_response(data: { requested: rows.size, scheduled: scheduled, skipped: rows.size - scheduled,
                             next_cursor: has_more ? rows.last&.id : nil, done: !has_more })
  rescue PipelineClassification::Catalog::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def runtime_settings
    authorize @pipeline, :show?
    success_response(data: runtime_settings_data)
  end

  def update_runtime_settings
    authorize @pipeline, :show?
    updates = params.permit(*PipelineClassification::RuntimeSettings::FIELDS).to_h.deep_stringify_keys
    raise PipelineClassification::Catalog::Invalid, 'runtime_settings_required' if updates.empty?

    persist_runtime_settings!(updates)
    success_response(data: runtime_settings_data)
  rescue PipelineClassification::Catalog::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def reset_provider
    authorize @pipeline, :show?
    PipelineClassification::CircuitBreaker.new.reset!(actor: Current.user)
    success_response(data: { provider_circuit: PipelineClassification::CircuitBreaker.new.status })
  rescue PipelineClassification::CircuitBreaker::Open => e
    render json: { error: e.message }, status: :forbidden
  end

  private

  def runtime_settings_data
    settings = PipelineClassification::Budget.settings
    {
      automatic_moves_enabled: settings['automatic_moves_enabled'] == true,
      online_authorized: PipelineClassification::Budget.installation_authorized?,
      provider_configured: Ai::DecisionClient.status[:configured],
      provider_circuit: PipelineClassification::CircuitBreaker.new.status,
      budget: PipelineClassification::RuntimeSettings.public_settings(settings)
    }
  end

  def persist_runtime_settings!(updates)
    row = InstallationConfig.create_or_find_by!(name: 'PIPELINE_CLASSIFICATION_SETTINGS') { |config| config.value = {} }
    row.with_lock do
      current = row.value.is_a?(Hash) ? row.value.deep_stringify_keys : {}
      settings = current.merge(updates)
      PipelineClassification::RuntimeSettings.new(settings: settings, updated_keys: updates.keys).validate!
      row.update!(value: settings)
    end
  end

  def result_data(row)
    target = classification_target(row)
    stage = target&.fetch('stages', [])&.find { |candidate| candidate['id'] == row.decision['recommended_stage_id'] }
    {
      id: row.id, conversation_id: row.conversation_id, status: row.status, reason: row.reason,
      created_at: row.created_at&.iso8601, expires_at: row.expires_at&.iso8601,
      recommended_pipeline_name: target&.fetch('name', nil), recommended_stage_name: stage&.fetch('name', nil),
      decision: row.decision.slice('pipeline_confidence', 'confidence', 'recommended_pipeline_id', 'recommended_stage_id',
                                   'application', 'provider_latency_ms', 'cost_usd')
    }
  end

  def classification_target(row)
    targets = row.pipeline_classification_catalog&.snapshot&.fetch('routing_targets', [])
    targets&.find { |target| target['pipeline_id'] == row.decision['recommended_pipeline_id'] }
  end

  def human_operator!
    return if Current.user.is_a?(User) && !service_authenticated?

    render json: { error: 'human_operator_required' }, status: :forbidden
  end

  def load_pipeline!
    # Do not use the service-token widening of PipelinePolicy::Scope for writes.
    @pipeline = policy_scope(Pipeline).find(params[:pipeline_id])
  end

  def expected_hash
    params[:expected_hash].presence || request.headers['If-Match'].to_s.delete_prefix('"').delete_suffix('"')
  end

  def catalog_payload
    params.permit!.to_h.slice('classification', 'stages')
  end

  def render_catalog
    PipelineClassification::Catalog.new(@pipeline.reload)
    status = if defined?(Ai::DecisionClient)
               Ai::DecisionClient.status
             else
               { configured: false, provider: 'openrouter' }
             end
    data = nil
    @pipeline.with_lock { data = PipelineClassification::Catalog.new(@pipeline).representation }
    response.headers['ETag'] = %("#{data.fetch('draft_hash')}")
    success_response(data: data.merge('credential_status' => status))
  end
end
