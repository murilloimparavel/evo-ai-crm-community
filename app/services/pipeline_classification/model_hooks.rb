module PipelineClassification
  # Runs after commit so writers do not hold conversation/contact locks while
  # the classifier acquires its pipeline -> conversation lock order.
  class ModelHooks
    INVALID_CONTENT_FLAGS = %w[deleted revoked_by_contact cancelled canceled].freeze
    def self.ready?
      PipelineClassificationState.table_exists?
    end

    # List every public-message invalidation trigger before notifying the lifecycle once.
    def self.message_created(message) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      return unless ready? && !message.imported? && !message.private?

      conversation = Conversation.find_by(id: message.conversation_id)
      return unless conversation

      if message.incoming?
        Lifecycle.incoming!(conversation: conversation, message: message)
      elsif message.outgoing? && message.source_id.present? && !message.failed?
        Lifecycle.invalidate!(conversation: conversation, reason: 'public_outbound_changed')
      end
    end

    # List every public-message invalidation trigger before notifying the lifecycle once.
    def self.message_updated(message) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      return unless ready? && !message.imported?
      return if message.private? && !message.saved_changes.key?('private')

      fields = %w[content content_type private message_type source_id]
      changed = message.saved_changes.keys.intersect?(fields)
      status_change = message.saved_changes['status']
      changed ||= status_change&.map(&:to_s)&.include?('failed')
      %w[content_attributes additional_attributes].each do |key|
        next unless message.saved_changes[key]

        previous, current = message.saved_changes[key].map { |value| value.is_a?(Hash) ? value.stringify_keys : {} }
        changed ||= INVALID_CONTENT_FLAGS.any? { |field| previous[field] != current[field] }
      end
      return unless changed

      conversation = Conversation.find_by(id: message.conversation_id)
      Lifecycle.invalidate!(conversation: conversation, reason: 'public_message_changed') if conversation
    end

    def self.conversation_updated(conversation)
      return unless ready?

      fields = %w[status assignee_id team_id inbox_id contact_id snoozed_until]
      changed = conversation.saved_changes.keys.intersect?(fields)
      labels_changed = conversation.respond_to?(:saved_change_to_label_list?) && conversation.saved_change_to_label_list?
      if changed || labels_changed
        Lifecycle.invalidate!(conversation: conversation, reason: 'conversation_changed')
      elsif conversation.saved_changes.key?('custom_attributes')
        Lifecycle.context_changed!(conversation: conversation)
      end
    end

    def self.contact_updated(contact)
      return unless ready?

      changed = contact.saved_changes.key?('blocked') ||
                (contact.respond_to?(:saved_change_to_label_list?) && contact.saved_change_to_label_list?)
      context_changed = contact.saved_changes.key?('custom_attributes')
      return unless changed || context_changed

      contact.conversations.find_each do |conversation|
        if changed
          Lifecycle.invalidate!(conversation: conversation, reason: 'contact_changed')
        else
          Lifecycle.context_changed!(conversation: conversation)
        end
      end
    end

    def self.pipeline_item_changed(item)
      return unless ready?

      fields = %w[pipeline_stage_id pipeline_id completed_at conversation_id]
      return unless item.destroyed? || item.previously_new_record? || item.saved_changes.keys.intersect?(fields)

      ids = [item.conversation_id, item.saved_changes.dig('conversation_id', 0)].compact.uniq
      Conversation.where(id: ids).find_each do |conversation|
        Lifecycle.invalidate!(conversation: conversation, reason: 'pipeline_item_changed')
      end
    end
  end
end
