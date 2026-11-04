module PipelineClassification
  # Read validity under the evaluator lock and again when a consumer reads a result.
  module EvaluationGuard
    private

    # Revalidate every current-result safety gate together before accepting or consuming a result.
    def invalid_reason # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      pipeline = @row.pipeline
      conversation = @row.conversation
      catalog = @row.pipeline_classification_catalog
      return 'missing_target' unless pipeline && conversation && catalog
      return 'catalog_changed' unless Lifecycle.active_catalog(pipeline)&.id == catalog.id && catalog.catalog_hash == @row.catalog_hash

      profile = catalog.snapshot.fetch('classification')
      return 'inbox_not_allowed' unless profile['inbox_ids'].include?(conversation.inbox_id)
      return 'closed_conversation' unless %w[open pending].include?(conversation.status)
      return 'human_assignee' if conversation.assignee_id.present? || conversation.team_id.present?
      return 'contact_blocked' unless conversation.contact && !conversation.contact.reload.blocked?

      binding = conversation.inbox.agent_bot_inbox
      if binding && !(binding.active? && !binding.has_ignored_labels?(conversation) && !binding.processing_block_reason(conversation))
        return 'inbox_bot_policy_block'
      end

      items = conversation.pipeline_items.where(pipeline_id: pipeline.id, completed_at: nil)
      return 'missing_pipeline_item' unless items.count == 1
      return 'pipeline_mismatch' unless items.first.pipeline_stage.pipeline_id == pipeline.id

      state = PipelineClassificationState.find_by(pipeline_id: pipeline.id, conversation_id: conversation.id)
      unless state && state.generation == @row.generation && state.revision == @row.revision &&
             state.source_incoming_message_id == @row.source_incoming_message_id
        return 'stale_generation'
      end
      return 'selected_context_changed' unless state.context_digest == Lifecycle.context_digest(pipeline, conversation)

      incoming = conversation.messages.find_by(id: @row.source_incoming_message_id, message_type: :incoming, private: false)
      return 'missing_source_incoming' unless incoming
      return 'incoming_changed' if conversation.messages.incoming.where(private: false).exists?(['created_at > ?', incoming.created_at])

      human = conversation.messages.outgoing.where(private: false).where('created_at >= ?', incoming.created_at)
      if human.exists?(sender_type: 'User') || human.where("content_attributes ->> 'whatsapp_echo_message' = 'true'").exists?
        return 'human_intervention'
      end
      return 'classification_expired' unless @row.expires_at && @row.expires_at > now

      nil
    end
  end
end
