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

      def active_catalog(pipeline)
        catalog = Catalog.new(pipeline)
        return unless pipeline.is_active? && catalog.current?

        profile = catalog.snapshot.fetch('classification')
        return unless profile['enabled'] == true && profile['mode'] == 'observe'

        catalog.published
      rescue Catalog::Invalid
        nil
      end

      def context_digest(pipeline, conversation)
        config = Catalog.new(pipeline).snapshot.dig('classification', 'context_sources')
        Catalog.digest(Followups::SnapshotContext.new(config).call(conversation: conversation))
      rescue Catalog::Invalid, Followups::SnapshotContext::Invalid, Followups::SnapshotContext::InvalidValue
        'invalid_context'
      end

      def latest_incoming(conversation)
        # Existing state owns ordering once the event is accepted. Initial card
        # creation has no prior state; timestamps alone cannot reconstruct ties.
        messages = conversation.messages.where(private: false, message_type: :incoming)
        at = messages.maximum(:created_at)
        return unless at

        candidates = messages.where(created_at: at).limit(2).to_a
        return candidates.first if candidates.size == 1

        # The follow-up state is an existing event acceptance record; absent a
        # matching accepted source, an ambiguous initial tie must abstain.
        accepted_id = FollowupConversationState.find_by(conversation_id: conversation.id)&.latest_incoming_message_id
        candidates.find { |message| message.id == accepted_id }
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
        PipelineClassificationResult.where(pipeline_id: pipeline.id, conversation_id: conversation.id)
                                    # Bulk cancellation is guarded by the parent pipeline/conversation/state lock above.
                                    .where.not(status: %w[cancelled blocked]).update_all( # rubocop:disable Rails/SkipsModelValidations
                                      status: 'cancelled', reason: reason, lease_expires_at: nil
                                    )
      end
    end
  end
end
