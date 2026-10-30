module Followups
  # A bounded incident record lives in the execution ledger; the campaign is
  # stopped atomically. Never attempt to repair a customer's data automatically.
  class SafetyStop
    REASONS = %w[message_identity_mismatch provider_reference_conflict].freeze

    def self.trip!(execution:, reason:, now: Time.current)
      raise ArgumentError, 'unsupported safety incident' unless REASONS.include?(reason)

      campaign = execution.followup_campaign
      campaign.with_lock do
        campaign.update_columns(enabled: false, mode: 'off', updated_at: now)
        FollowupExecution.where(followup_campaign_id: campaign.id, status: FollowupExecution::PENDING)
                         .update_all(status: 'cancelled', reason: 'incident_campaign_stopped', finalized_at: now, updated_at: now)
        FollowupClassification.where(followup_campaign_id: campaign.id, status: %w[reserved evaluating retryable_error])
                              .update_all(status: 'cancelled', reason: 'incident_campaign_stopped', updated_at: now)
        execution.reload
        uncertain = %w[dispatching dispatched delivered read delivery_unknown].include?(execution.status)
        execution.update!(status: uncertain ? 'delivery_unknown' : 'cancelled', reason: "incident_#{reason}",
                          finalized_at: now, lease_expires_at: nil)
      end
      # Do not acquire conversation-state locks while holding the campaign lock.
      ids = FollowupExecution.where(followup_campaign_id: campaign.id).select(:id)
      FollowupConversationState.where(active_execution_id: ids).update_all(active_execution_id: nil, updated_at: now)
      Rails.logger.error({ event: 'followup_safety_stop', campaign_id: campaign.id,
                           execution_id: execution.id, reason: reason }.to_json)
      false
    end

    def self.check_identity(message)
      execution = FollowupExecution.find_by(id: message.followup_execution_id)
      return false unless execution
      return true if execution.message_id == message.id && execution.conversation_id == message.conversation_id &&
                     execution.followup_campaign.inbox_id == message.inbox_id

      trip!(execution: execution, reason: 'message_identity_mismatch')
    end

    def self.check_receipt(message)
      execution = FollowupExecution.find_by(id: message.followup_execution_id, message_id: message.id)
      return false unless execution
      return true if execution.external_provider_id.blank? || message.source_id.blank? ||
                     execution.external_provider_id == message.source_id

      trip!(execution: execution, reason: 'provider_reference_conflict')
    end
  end
end
