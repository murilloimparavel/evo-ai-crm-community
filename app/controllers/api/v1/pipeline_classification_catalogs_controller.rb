class Api::V1::PipelineClassificationCatalogsController < Api::V1::BaseController
  wrap_parameters false
  require_permissions({ show: 'pipelines.read', projection: 'pipelines.read', update: 'pipelines.update', preview: 'pipelines.update',
                        publish: 'pipelines.update' })
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
    catalog = PipelineClassification::Catalog.new(@pipeline, payload: catalog_payload)
    success_response(data: { valid: true, compiled: catalog.compiled, draft_hash: catalog.hash, legacy_reference: catalog.legacy_reference })
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

  private

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
