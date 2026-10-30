module Followups
  # Runs at the shared channel boundary, including direct channel service calls.
  # The persistent claim protects two workers sending the SAME Message.
  class DispatchProtection
    def self.managed?(message)
      message.has_attribute?(:followup_execution_id) && message.followup_execution_id.present?
    end

    def self.perform(message:)
      execution = FollowupExecution.find_by(id: message.followup_execution_id)
      unless execution&.target_available?
        Retention.retire!(execution) if execution
        return
      end
      return unless SafetyStop.check_identity(message)
      if message.source_id.present?
        return unless SafetyStop.check_receipt(message)
        DeliveryTracker.status_changed(message: message, status: message.status, provider_id: message.source_id)
        return
      end
      claim = DispatchGuard.claim(message: message)
      return unless claim
      return unless DispatchGuard.preflight(claim: claim, message: message)

      prior_retry_count = message.content_attributes.to_h['whatsapp_auto_retry_count'].to_i
      if message.failed?
        # Only a positively rejected, still-authorized retry can reach this claim.
        # Clear the local failure; the execution is the dispatch authority.
        message.update!(status: :sent, content_attributes: message.content_attributes.to_h.except('external_error'))
      end
      result = yield
      message.reload
      attrs = message.content_attributes.to_h
      if message.source_id.present?
        DeliveryTracker.accepted(message: message, claim: claim, provider_id: message.source_id)
        DeliveryTracker.status_changed(message: message, status: message.status, provider_id: message.source_id)
      elsif message.failed? && attrs['whatsapp_auto_retry_http_status'].to_i == 429 &&
            attrs['whatsapp_auto_retry_count'].to_i > prior_retry_count
        # A new rejection marker from THIS attempt, never a leftover marker.
        delay = attrs['whatsapp_auto_retry_count'].to_i == 1 ? 5.seconds : 30.seconds
        DeliveryTracker.rate_limited(message: message, claim: claim, retry_at: Time.current + delay)
      elsif message.is_unsupported.present?
        DeliveryTracker.permanent_failure(message: message, claim: claim, reason: 'unsupported_content')
      else
        DeliveryTracker.unknown(message: message, claim: claim)
      end
      result
    rescue StandardError
      # No retry on an ambiguous external result. Preserve the message and ledger.
      DeliveryTracker.unknown(message: message, claim: claim) if claim
      raise
    end
  end
end
