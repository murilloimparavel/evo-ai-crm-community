# frozen_string_literal: true

module BotRuntime
  class DeliverPendingEventJob < ApplicationJob
    queue_as :bot_runtime
    LEASE_DURATION = 10.minutes

    def perform(delivery_id)
      return unless Config.enabled?

      delivery = Delivery.find_by(id: delivery_id)
      return unless delivery

      token = SecureRandom.uuid
      claimed = claim(delivery, token)
      deliver(delivery, token) if claimed
    rescue StandardError => e
      raise unless claimed

      delay = [2**[delivery.attempts, 10].min, 600].min.seconds
      finalize(delivery, token, next_attempt_at: delay.from_now, last_error: e.class.name)
      Rails.logger.warn "[BotRuntime] Delivery pending id=#{delivery.id} error=#{e.class.name}"
    end

    private

    def claim(delivery, token)
      delivery.with_lock do
        next false if delivery.delivered_at || delivery.skipped_at || delivery.next_attempt_at > Time.current

        delivery.update!(attempts: delivery.attempts + 1, lease_token: token, next_attempt_at: LEASE_DURATION.from_now)
        true
      end
    end

    def deliver(delivery, token)
      # Never hold a database transaction while transcribing or making HTTP calls.
      message = delivery.message
      reason = eligibility_block_reason(delivery, message)
      if reason
        finalize(delivery, token, skipped_at: Time.current, skipped_reason: reason)
        return
      end

      event = DelegationService.new(delivery.agent_bot, message, message.conversation).build_message_event
      event[:message_content] = delivery.message_content
      result = TranscriptionEnricher.enrich(event, in_progress_fallback: delivery.attempts >= 27)
      finish_enrichment(delivery, token, result, event)
    end

    def finish_enrichment(delivery, token, result, event)
      if result.in_progress
        finalize(delivery, token, next_attempt_at: 5.seconds.from_now)
        self.class.set(wait: 5.seconds).perform_later(delivery.id)
        return
      end

      fallback_needed = result.fallback_reasons.present? && !result.forward_to_agent
      raise 'Audio fallback delivery failed' if fallback_needed && !AudioFallbackService.deliver(event, reasons: result.fallback_reasons)

      Client.new.send_event(result.event) if result.forward_to_agent
      finalize(delivery, token, delivered_at: Time.current, last_error: nil)
    end

    def eligibility_block_reason(delivery, message)
      assignment = message.conversation.inbox.agent_bot_inbox
      return 'bot_inactive' unless assignment&.active?

      assigned_ids = [assignment.agent_bot_id]
      assigned_ids << assignment.facebook_comment_agent_bot_id if message.conversation.post_conversation?
      return 'bot_assignment_changed' unless assigned_ids.compact.map(&:to_s).include?(delivery.agent_bot_id.to_s)

      reason = assignment.processing_block_reason(message.conversation)
      reason.present? ? "conversation_gate:#{reason}" : nil
    end

    def finalize(delivery, token, **attributes)
      delivery.with_lock do
        # An expired worker cannot acknowledge or postpone a newer attempt.
        delivery.update!(**attributes, lease_token: nil) if delivery.lease_token == token
      end
    end
  end
end
