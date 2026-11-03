module PipelineClassification
  class DebouncedClassifier
    def initialize(state:, generation:, now: Time.current)
      @state = state
      @generation = generation
      @now = now
    end

    # Keep generation checks and result creation in the same ordered lock scope.
    def call # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      row = nil
      @state.pipeline.with_lock do
        @state.conversation.with_lock do
          @state.lock!
          next unless @state.generation == @generation && @state.due_at && @state.due_at <= @now

          catalog = Lifecycle.active_catalog(@state.pipeline)
          unless catalog && @state.conversation.messages.incoming.exists?(id: @state.source_incoming_message_id)
            @state.update!(due_at: nil)
            next
          end
          profile = catalog.snapshot.fetch('classification')
          row = PipelineClassificationResult.create_or_find_by!(pipeline: @state.pipeline, conversation: @state.conversation,
                                                                generation: @state.generation, catalog_hash: catalog.catalog_hash,
                                                                model: profile.fetch('model'),
                                                                question_version: profile.fetch('question_version')) do |result|
            result.pipeline_classification_catalog = catalog
            result.revision = @state.revision
            result.source_incoming_message_id = @state.source_incoming_message_id
            result.expires_at = @now + profile.fetch('result_ttl_seconds').seconds
          end
          @state.update!(due_at: nil)
        end
      end
      row
    end
  end
end
