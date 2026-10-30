module Followups
  # Synchronous invalidation hooks run inside the writer transaction. Sending
  # also reloads authoritative data; asynchronous event delivery isn't a guard.
  class Lifecycle
    CONVERSATION_FIELDS = %w[status assignee_id team_id inbox_id contact_id snoozed_until].freeze

    def self.interested?(conversation)
      return false unless conversation&.persisted?
      return false unless FollowupCampaign.table_exists?

      FollowupCampaign.exists?(inbox_id: conversation.inbox_id, enabled: true) ||
        FollowupConversationState.exists?(conversation_id: conversation.id)
    end

    def self.message_created(message)
      return if message.private? || message.imported? || DispatchProtection.managed?(message)

      conversation = Conversation.find_by(id: message.conversation_id)
      return unless interested?(conversation)

      if message.incoming?
        DebounceCoordinator.on_incoming!(message: message)
      elsif message.outgoing?
        Cancellation.invalidate(conversation: conversation, reason: 'public_outbound_changed')
      end
    end

    def self.message_updated(message)
      return if DispatchProtection.managed?(message)
      return unless message.saved_changes.keys.intersect?(%w[content content_type private message_type])

      conversation = Conversation.find_by(id: message.conversation_id)
      return unless interested?(conversation)

      Cancellation.invalidate(conversation: conversation, reason: 'public_message_changed')
    end

    def self.conversation_updated(conversation)
      changed = conversation.saved_changes.keys.intersect?(CONVERSATION_FIELDS)
      labels_changed = conversation.respond_to?(:saved_change_to_label_list?) && conversation.saved_change_to_label_list?
      target = Conversation.find_by(id: conversation.id)
      return unless interested?(target)

      if context_changed?(conversation: target, record: conversation, source: 'conversation.custom_attributes')
        DebounceCoordinator.refresh!(conversation: target, reason: 'classification_context_changed')
        return
      end
      return unless changed || labels_changed

      Cancellation.invalidate(conversation: target, reason: changed ? 'conversation_changed' : 'labels_changed')
    end

    # Selected-source invalidation must retain its complete existing mutation and event checks.
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def self.contact_updated(contact)
      labels_changed = contact.respond_to?(:saved_change_to_label_list?) && contact.saved_change_to_label_list?
      return unless contact.saved_change_to_blocked? || labels_changed || contact.saved_changes.key?('custom_attributes')

      contact.conversations.find_each do |conversation|
        next unless interested?(conversation)

        if context_changed?(conversation: conversation, record: contact, source: 'contact.custom_attributes')
          DebounceCoordinator.refresh!(conversation: conversation, reason: 'classification_context_changed')
        elsif contact.saved_change_to_blocked? || labels_changed
          Cancellation.invalidate(conversation: conversation, reason: 'contact_changed')
        end
      end
    end
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    # Selected-source invalidation must retain its complete existing mutation and event checks.
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def self.context_changed?(conversation:, record:, source:)
      change = record.saved_changes['custom_attributes']
      return false unless change.is_a?(Array) && change.size == 2

      before, after = change.map { |value| value.is_a?(Hash) ? value.stringify_keys : {} }
      FollowupCampaign.where(inbox_id: conversation.inbox_id, enabled: true).any? do |campaign|
        fields = campaign.policy.dig('snapshot_context', 'fields')
        fields.is_a?(Array) && fields.any? do |field|
          field.is_a?(Hash) && field['source'] == source && before[field['field']] != after[field['field']]
        end
      end
    end
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    def self.pipeline_item_updated(item)
      return unless item.saved_changes.keys.intersect?(%w[pipeline_stage_id pipeline_id completed_at conversation_id])

      ids = [item.conversation_id, item.saved_changes.dig('conversation_id', 0)].compact.uniq
      Conversation.where(id: ids).find_each do |conversation|
        next unless interested?(conversation)

        DebounceCoordinator.refresh!(conversation: conversation, reason: 'stage_changed')
      end
    end

    def self.pipeline_item_destroyed(item)
      conversation = Conversation.find_by(id: item.conversation_id)
      return unless interested?(conversation)

      Cancellation.invalidate(conversation: conversation, reason: 'stage_link_removed')
    end

    # Called AFTER commit: a campaign write must not hold a campaign row lock
    # while acquiring conversation locks in the reverse order of dispatch.
    def self.campaign_updated(campaign)
      return unless campaign.saved_changes.keys.intersect?(%w[policy policy_version enabled mode active_from expires_at inbox_id pipeline_stage_id])

      ids = FollowupClassification.where(followup_campaign_id: campaign.id).select(:conversation_id)
      evidence_ids = FollowupAnchorEvidence.where(followup_campaign_id: campaign.id).select(:conversation_id)
      execution_ids = FollowupExecution.where(followup_campaign_id: campaign.id).select(:conversation_id)
      Conversation.where(id: ids).or(Conversation.where(id: evidence_ids)).or(Conversation.where(id: execution_ids)).find_each do |conversation|
        DebounceCoordinator.refresh!(conversation: conversation, reason: 'campaign_changed')
      end
    end
  end
end
