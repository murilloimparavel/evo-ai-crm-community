module PipelineClassification
  class Editor
    def initialize(pipeline:, actor:)
      @pipeline, @actor = pipeline, actor
    end

    # Aggregate lock order: pipeline, all stages by stable id, then classification
    # state. All stage writes also acquire the parent pipeline lock first.
    def save!(payload:, expected_hash:)
      @pipeline.with_lock do
        @pipeline.pipeline_stages.reorder(:id).lock.load
        verify_hash!(expected_hash)
        catalog = Catalog.new(@pipeline, payload: payload)
        snapshot = catalog.snapshot
        catalog.compiled
        if snapshot.dig('classification', 'enabled') && !Budget.installation_authorized?
          raise Catalog::Invalid, 'online_approvals_required'
        end
        @pipeline.update!(config: (@pipeline.config || {}).merge('classification' => snapshot.fetch('classification')))
        snapshot.fetch('stages').each do |stage|
          @pipeline.pipeline_stages.find(stage.fetch('id')).update!(classification_profile: stage.fetch('classification_profile'))
        end
        Lifecycle.pipeline_changed!(pipeline: @pipeline)
        Catalog.new(@pipeline.reload).representation
      end
    end

    def publish!(expected_hash:)
      @pipeline.with_lock do
        @pipeline.pipeline_stages.reorder(:id).lock.load
        verify_hash!(expected_hash)
        catalog = Catalog.new(@pipeline)
        catalog.compiled
        raise Catalog::Invalid, 'purpose_required' if catalog.snapshot.dig('classification', 'purpose').blank?
        raise Catalog::Invalid, 'participating_stage_required' unless catalog.snapshot['stages'].any? { |stage| stage.dig('classification_profile', 'classification_enabled') }
        return catalog.published if catalog.current?

        revision = @pipeline.pipeline_classification_catalogs.create!(catalog_version: (@pipeline.pipeline_classification_catalogs.maximum(:catalog_version) || 0) + 1,
          catalog_hash: catalog.hash, snapshot: catalog.snapshot, approved_by: @actor, approved_at: Time.current, created_at: Time.current)
        Lifecycle.pipeline_changed!(pipeline: @pipeline)
        revision
      end
    end

    private

    def verify_hash!(expected)
      raise Catalog::Conflict, 'catalog_revision_conflict' unless expected.is_a?(String) && expected == Catalog.new(@pipeline).hash
    end
  end
end
