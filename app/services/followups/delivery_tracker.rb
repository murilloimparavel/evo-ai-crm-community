module Followups
  class DeliveryTracker
    # Retain the shared adapter keyword interface even when this implementation does not consume every argument.
    # rubocop:disable Lint/UnusedMethodArgument
    def self.accepted(message:, claim:, provider_id:, now: Time.current)
      # rubocop:enable Lint/UnusedMethodArgument
      return false if provider_id.blank?

      transition_claim(message, claim) do |execution|
        execution.update!(status: 'dispatched', external_provider_id: provider_id.to_s, lease_expires_at: nil, reason: 'provider_accepted')
      end
    end

    def self.rate_limited(message:, claim:, retry_at:, now: Time.current)
      transition_claim(message, claim) do |execution|
        reason = Eligibility.new(campaign: execution.followup_campaign, conversation: message.conversation, execution: execution, now: now,
                                 dispatch: true).reason
        if reason || !retry_at.is_a?(Time) || retry_at >= execution.expires_at
          execution.update!(status: 'cancelled', reason: reason || 'retry_exceeds_expiry', finalized_at: now, lease_expires_at: nil)
        else
          execution.update!(status: 'queued', reason: 'provider_rate_limited', next_attempt_at: retry_at, lease_expires_at: nil)
        end
      end
    end

    # Retain the shared adapter keyword interface even when this implementation does not consume every argument.
    # rubocop:disable Lint/UnusedMethodArgument
    def self.unknown(message:, claim:, now: Time.current)
      # rubocop:enable Lint/UnusedMethodArgument
      transition_claim(message, claim) do |execution|
        execution.update!(status: 'delivery_unknown', reason: 'provider_outcome_unknown', lease_expires_at: nil)
      end
    end

    def self.permanent_failure(message:, claim:, reason: 'provider_rejected', now: Time.current)
      transition_claim(message, claim) do |execution|
        execution.update!(status: 'permanent_failure', reason: reason, lease_expires_at: nil, finalized_at: now)
      end
    end

    # Invoked even if Message's legacy state machine considers failed terminal.
    # Correlation and monotonic advancement make late/duplicate callbacks safe.
    # Retain correlation, monotonic status checks and fencing in the same delivery transaction.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def self.status_changed(message:, status:, provider_id: nil, now: Time.current)
      return false unless message.followup_execution_id
      return false unless %w[sent delivered read failed].include?(status.to_s)

      execution = FollowupExecution.find_by(id: message.followup_execution_id, message_id: message.id)
      return false unless execution

      execution.with_lock do
        next false unless execution.conversation_id == message.conversation_id

        incoming_id = provider_id.presence || message.source_id.presence
        next false unless incoming_id
        next false if execution.external_provider_id.present? && execution.external_provider_id != incoming_id
        next false unless %w[queued dispatching dispatched delivery_unknown permanent_failure delivered read].include?(execution.status)
        next false if execution.status == 'read'

        target = { 'sent' => 'dispatched', 'delivered' => 'delivered', 'read' => 'read', 'failed' => 'permanent_failure' }.fetch(status.to_s)
        next false if execution.status == 'delivered' && %w[dispatched permanent_failure].include?(target)
        next false if target == execution.status

        execution.update!(status: target, external_provider_id: incoming_id, reason: 'provider_status', lease_expires_at: nil,
                          finalized_at: %w[delivered read permanent_failure].include?(target) ? now : nil)
        true
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    def self.transition_claim(message, claim)
      return false unless claim

      execution = FollowupExecution.find_by(id: claim.execution_id, message_id: message.id)
      return false unless execution

      execution.with_lock do
        next false unless execution.status == 'dispatching' && execution.fence_token == claim.fence_token

        yield execution
        true
      end
    end
    private_class_method :transition_claim
  end
end
