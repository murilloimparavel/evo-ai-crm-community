module PipelineClassification
  class Editor
    def initialize(pipeline:, actor:)
      @pipeline = pipeline
      @actor = actor
    end

    def preview!(payload:)
      catalog = Catalog.new(@pipeline, payload: payload)
      compiled = catalog.compiled
      authorize_routing_targets!(catalog)
      { valid: true, compiled: compiled, draft_hash: catalog.hash, legacy_reference: catalog.legacy_reference }
    end

    # Aggregate lock order: pipeline, all stages by stable id, then classification
    # state. All stage writes also acquire the parent pipeline lock first.
    # Keep optimistic hash validation and all aggregate writes in one ordered transaction.
    def save!(payload:, expected_hash:) # rubocop:disable Metrics/AbcSize
      @pipeline.with_lock do
        @pipeline.pipeline_stages.reorder(:id).lock.load
        verify_hash!(expected_hash)
        catalog = Catalog.new(@pipeline, payload: payload)
        snapshot = catalog.snapshot
        catalog.compiled
        authorize_routing_targets!(catalog)
        raise Catalog::Invalid, 'online_approvals_required' if snapshot.dig('classification', 'enabled') && !Budget.installation_authorized?

        @pipeline.update!(config: (@pipeline.config || {}).merge('classification' => snapshot.fetch('classification')))
        snapshot.fetch('stages').each do |stage|
          @pipeline.pipeline_stages.find(stage.fetch('id')).update!(classification_profile: stage.fetch('classification_profile'))
        end
        Lifecycle.pipeline_changed!(pipeline: @pipeline)
        Catalog.new(@pipeline.reload).representation
      end
    end

    # Keep optimistic hash validation and all aggregate writes in one ordered transaction.
    def publish!(expected_hash:) # rubocop:disable Metrics/AbcSize
      @pipeline.with_lock do
        @pipeline.pipeline_stages.reorder(:id).lock.load
        verify_hash!(expected_hash)
        catalog = Catalog.new(@pipeline)
        catalog.compiled
        authorize_routing_targets!(catalog)
        raise Catalog::Invalid, 'purpose_required' if catalog.snapshot.dig('classification', 'purpose').blank?
        raise Catalog::Invalid, 'participating_stage_required' unless catalog.snapshot['stages'].any? do |stage|
          stage.dig('classification_profile', 'classification_enabled')
        end
        next catalog.published if catalog.current?

        next_version = (@pipeline.pipeline_classification_catalogs.maximum(:catalog_version) || 0) + 1
        revision = @pipeline.pipeline_classification_catalogs.create!(catalog_version: next_version,
                                                                      catalog_hash: catalog.hash, snapshot: catalog.snapshot,
                                                                      approved_by: @actor, approved_at: Time.current, created_at: Time.current)
        Lifecycle.pipeline_changed!(pipeline: @pipeline)
        revision
      end
    end

    private

    def verify_hash!(expected)
      raise Catalog::Conflict, 'catalog_revision_conflict' unless expected.is_a?(String) && expected == Catalog.new(@pipeline).hash
    end

    def authorize_routing_targets!(catalog)
      ids = catalog.snapshot.dig('classification', 'routing_pipeline_ids')
      ids = [@pipeline.id] if ids.empty?
      scope = PipelinePolicy::Scope.new({ user: @actor, service_authenticated: false }, Pipeline).resolve
      permitted = scope.where(id: ids).pluck(:id)
      raise Catalog::Invalid, 'routing_pipeline_access_denied' unless permitted.sort == ids.sort
    end
  end
end
