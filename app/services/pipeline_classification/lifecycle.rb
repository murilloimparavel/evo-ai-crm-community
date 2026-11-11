module PipelineClassification
  class Lifecycle
    class << self
      # Keep accepted-event generation, invalidation and debounce updates under the same ordered locks.
      def incoming!(conversation:, message:, now: Time.current) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
        return unless message.incoming? && !message.private? && message.conversation_id == conversation.id

        pipelines_for(conversation).find_each do |pipeline|
          pipeline.with_lock do
            conversation.with_lock do
              state = state_for!(pipeline, conversation)
              state.lock!
              # The incoming event's acceptance under this lock is the tie-breaker
              # for equal timestamps. Replayed events must not open a new cycle.
              receipt = PipelineClassificationEvent.create_or_find_by!(pipeline: pipeline, conversation: conversation,
                                                                       message_id: message.id) do |event|
                event.created_at = now
                event.accepted_generation = state.generation + 1
              end
              next unless receipt.previously_new_record?
              next if state.source_incoming_message_id == message.id

              previous = conversation.messages.find_by(id: state.source_incoming_message_id)
              next if previous && previous.created_at > message.created_at

              reset!(state, pipeline, conversation, source_id: message.id, now: now)
            end
          end
        end
      end

      def invalidate!(conversation:, reason: 'context_changed', now: Time.current)
        pipelines_for(conversation).find_each do |pipeline|
          pipeline.with_lock do
            conversation.with_lock do
              state = state_for!(pipeline, conversation)
              state.lock!
              source = conversation.messages.find_by(id: state.source_incoming_message_id) || latest_incoming(conversation)
              reset!(state, pipeline, conversation, source_id: source&.id, now: now, reason: reason)
            end
          end
        end
      end

      def context_changed!(conversation:, now: Time.current)
        pipelines_for(conversation).find_each do |pipeline|
          pipeline.with_lock do
            conversation.with_lock do
              state = state_for!(pipeline, conversation)
              state.lock!
              digest = context_digest(pipeline, conversation)
              next if state.context_digest == digest

              source = conversation.messages.find_by(id: state.source_incoming_message_id) || latest_incoming(conversation)
              reset!(state, pipeline, conversation, source_id: source&.id, now: now)
            end
          end
        end
      end

      def pipeline_changed!(pipeline:, now: Time.current)
        pipeline.with_lock do
          PipelineClassificationState.where(pipeline_id: pipeline.id).find_each do |state|
            conversation = Conversation.find_by(id: state.conversation_id)
            next unless conversation

            conversation.with_lock do
              state.lock!
              reset!(state, pipeline, conversation, source_id: state.source_incoming_message_id, now: now, reason: 'catalog_changed')
            end
          end
        end
      end

      # Queue one bounded historical conversation without rewriting its messages.
      # A current result or pending debounce makes repeated backfill calls idempotent.
      def backfill!(pipeline:, conversation:, now: Time.current) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
        scheduled = false
        pipeline.with_lock do
          conversation.with_lock do
            state = state_for!(pipeline, conversation)
            state.lock!
            source = latest_incoming(conversation)
            next unless source && active_catalog(pipeline)
            next unless conversation.pipeline_items.active.where(pipeline_id: pipeline.id).count == 1
            next if CurrentResult.call(pipeline: pipeline, conversation: conversation, now: now)
            next if state.source_incoming_message_id == source.id &&
                    (state.due_at.present? || PipelineClassificationResult.exists?(pipeline_id: pipeline.id,
                                                                                   conversation_id: conversation.id,
                                                                                   source_incoming_message_id: source.id,
                                                                                   status: %w[reserved evaluating retryable_error]))

            PipelineClassificationEvent.create_or_find_by!(pipeline: pipeline, conversation: conversation, message_id: source.id) do |event|
              event.created_at = now
              event.accepted_generation = state.generation + 1
            end
            reset!(state, pipeline, conversation, source_id: source.id, now: now, reason: 'backfill_refreshed')
            scheduled = state.due_at.present?
          end
        end
        scheduled
      end

      def active_catalog(pipeline)
        catalog = Catalog.new(pipeline)
        return unless pipeline.is_active? && catalog.current?

        profile = catalog.snapshot.fetch('classification')
        return unless profile['enabled'] == true && %w[observe auto].include?(profile['mode'])

        catalog.published
      rescue Catalog::Invalid
        nil
      end

      def context_digest(pipeline, conversation)
        config = Catalog.new(pipeline).snapshot.dig('classification', 'context_sources')
        Catalog.digest(SnapshotContext.new(config).call(conversation: conversation))
      rescue Catalog::Invalid, SnapshotContext::Invalid, SnapshotContext::InvalidValue
        'invalid_context'
      end

      def latest_incoming(conversation)
        # Existing state owns ordering once the event is accepted. Initial card
        # creation has no prior state; timestamps alone cannot reconstruct ties.
        messages = conversation.messages.where(private: false, message_type: :incoming).where.not(status: :failed)
                               .where("COALESCE(content_attributes->>'deleted', 'false') != 'true'")
                               .where("COALESCE(content_attributes->>'revoked_by_contact', 'false') != 'true'")
        at = messages.maximum(:created_at)
        return unless at

        candidates = messages.where(created_at: at).limit(2).to_a
        return candidates.first if candidates.size == 1

        # Without an accepted event receipt, a timestamp tie has no safe winner.
        nil
      end

      def state_for!(pipeline, conversation)
        PipelineClassificationState.create_or_find_by!(pipeline: pipeline, conversation: conversation)
      end

      private

      def pipelines_for(conversation)
        ids = conversation.pipeline_items.where(completed_at: nil).select(:pipeline_id)
        existing = PipelineClassificationState.where(conversation_id: conversation.id).select(:pipeline_id)
        Pipeline.where(id: ids).where("config->'classification'->>'enabled' = 'true'").or(Pipeline.where(id: existing))
      end

      # Keep accepted-event generation, invalidation and debounce updates under the same ordered locks.
      def reset!(state, pipeline, conversation, source_id:, now:, reason: 'generation_changed') # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/ParameterLists
        revision = active_catalog(pipeline)
        profile = revision&.snapshot&.fetch('classification')
        items = conversation.pipeline_items.where(pipeline_id: pipeline.id, completed_at: nil)
        valid_item = items.count == 1 && items.first.pipeline_stage&.pipeline_id == pipeline.id
        allowed = profile && valid_item && profile['inbox_ids'].include?(conversation.inbox_id) && source_id.present?
        state.update!(generation: state.generation + 1, revision: state.revision + 1, source_incoming_message_id: source_id,
                      context_digest: context_digest(pipeline, conversation), due_at: allowed ? now + (profile['debounce_ms'] / 1000.0) : nil)
        results = PipelineClassificationResult.where(pipeline_id: pipeline.id, conversation_id: conversation.id)
                                              .where.not(status: %w[cancelled blocked])
        # Bulk cancellation is guarded by the parent pipeline/conversation/state lock above.
        results.update_all(status: 'cancelled', reason: reason, lease_expires_at: nil) # rubocop:disable Rails/SkipsModelValidations
      end
    end
  end
end
