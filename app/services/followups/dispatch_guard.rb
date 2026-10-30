module Followups
  class DispatchGuard
    Claim = Struct.new(:execution_id, :message_id, :fence_token, :revision, keyword_init: true)

    # Retain the complete fenced dispatch authorization checklist inside its existing lock boundary.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def self.claim(message:, retry_token: nil, now: Time.current)
      return nil unless message.followup_execution_id

      target = FollowupExecution.find_by(id: message.followup_execution_id)
      unless target&.target_available?
        Retention.retire!(target, now: now) if target
        return nil
      end

      claim = nil
      conversation = message.conversation
      conversation.with_lock do
        state = FollowupConversationState.for!(conversation)
        state.lock!
        execution = FollowupExecution.find_by(id: message.followup_execution_id)
        next nil unless execution

        execution.followup_campaign.lock!
        execution.lock!
        next nil unless execution.status == 'queued' && execution.message_id == message.id
        next nil if execution.next_attempt_at && execution.next_attempt_at > now

        reason = invalid_reason(message: message, execution: execution, now: now)
        if reason
          execution.update!(status: 'cancelled', reason: reason, finalized_at: now)
          next nil
        end
        next nil if retry_token && message.content_attributes.to_h['whatsapp_auto_retry_token'] != retry_token

        fence = execution.fence_token + 1
        changed = FollowupExecution.where(id: execution.id, status: 'queued', message_id: message.id, fence_token: execution.fence_token)
                                   # Keep this lifecycle-only SQL update atomic; callbacks must not reopen cancelled or fenced work.
                                   # rubocop:disable Rails/SkipsModelValidations
                                   .update_all(status: 'dispatching', fence_token: fence, lease_expires_at: now + 90.seconds, updated_at: now)
        # rubocop:enable Rails/SkipsModelValidations
        next nil unless changed == 1

        claim = Claim.new(execution_id: execution.id, message_id: message.id, fence_token: fence, revision: state.revision)
      end
      claim
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    # This is the last database authorization immediately before the one sender
    # invokes its provider. Committed mutations before this point invalidate it.
    # Retain the complete fenced dispatch authorization checklist inside its existing lock boundary.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def self.preflight(claim:, message:, now: Time.current)
      return false unless claim

      target = FollowupExecution.find_by(id: claim.execution_id)
      unless target&.target_available?
        Retention.retire!(target, now: now) if target
        return false
      end

      valid = false
      message.conversation.with_lock do
        state = FollowupConversationState.for!(message.conversation)
        state.lock!
        execution = FollowupExecution.find_by(id: claim.execution_id)
        next false unless execution

        execution.followup_campaign.lock!
        execution.lock!
        next false unless execution.status == 'dispatching' && execution.message_id == message.id && execution.fence_token == claim.fence_token

        reason = invalid_reason(message: message.reload, execution: execution, now: now)
        reason ||= 'revision_changed' unless state.revision == claim.revision
        reason ||= 'dispatch_lease_expired' unless execution.lease_expires_at && execution.lease_expires_at > now
        if reason
          execution.update!(status: 'cancelled', reason: reason, finalized_at: now)
        else
          valid = true
        end
      end
      valid
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    # Retain the complete fenced dispatch authorization checklist inside its existing lock boundary.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def self.invalid_reason(message:, execution:, now:)
      unless execution.message_id == message.id && execution.conversation_id == message.conversation_id &&
             execution.followup_campaign.inbox_id == message.inbox_id
        return 'message_identity_mismatch'
      end
      return 'message_not_public_outgoing' unless message.outgoing? && !message.private?

      if message.failed?
        attrs = message.content_attributes.to_h
        retry_allowed = execution.reason == 'provider_rate_limited' &&
                        attrs['whatsapp_auto_retry_http_status'].to_i == 429 && attrs['whatsapp_auto_retry_count'].to_i.positive? &&
                        attrs['whatsapp_auto_retry_token'].present?
        return 'message_failed_without_safe_retry' unless retry_allowed
      end
      return 'message_already_accepted' if message.source_id.present?
      return 'campaign_shadow' if execution.followup_campaign.mode == 'shadow'

      reason = Eligibility.new(campaign: execution.followup_campaign, conversation: message.conversation, execution: execution, now: now,
                               dispatch: true).reason
      return reason if reason

      template = FollowupTemplate.find_by(id: execution.template_id)
      unless template&.approved? && template.body == message.content &&
             template.version == message.content_attributes.to_h['followup_template_version']
        return 'template_changed'
      end

      nil
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end
