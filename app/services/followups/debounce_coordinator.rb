module Followups
  class DebounceCoordinator
    def self.on_incoming!(message:, now: Time.current)
      return unless message.incoming? && !message.private?

      # Message callbacks can retain an unsaved association (e.g. waiting_since).
      # Re-read the shared lock target rather than calling with_lock on it.
      conversation = Conversation.find(message.conversation_id)
      generation = nil
      deadline = nil
      conversation.with_lock do
        state = FollowupConversationState.for!(conversation)
        state.lock!
        latest = conversation.messages.incoming.find(message.id)
        next if state.latest_incoming_message_id == message.id
        previous = conversation.messages.incoming.find_by(id: state.latest_incoming_message_id)
        next if previous && previous.created_at > latest.created_at

        Cancellation.invalidate(conversation: conversation, reason: 'new_incoming', now: now)
        state.reload
        generation, deadline = update_deadline!(state: state, conversation: conversation, incoming: latest, now: now)
      end
      DebouncedClassificationJob.set(wait_until: deadline).perform_later(conversation.id, generation) if deadline
      generation
    end

    def self.refresh!(conversation:, reason:, now: Time.current)
      target = Conversation.find(conversation.id)
      generation = nil
      deadline = nil
      target.with_lock do
        state = FollowupConversationState.for!(target)
        state.lock!
        # Cancellation, latest-message read, generation and deadline all share
        # one transaction/lock. There is no intermediate cleared latest ID for
        # a concurrent inbound handler to overwrite or be overwritten by.
        Cancellation.invalidate(conversation: target, reason: reason, now: now)
        state.reload
        incoming = Eligibility.latest_incoming(target)
        generation, deadline = update_deadline!(state: state, conversation: target, incoming: incoming, now: now)
      end
      DebouncedClassificationJob.set(wait_until: deadline).perform_later(target.id, generation) if deadline
      generation
    end

    def self.campaigns_for(conversation, now: Time.current)
      stage_ids = conversation.pipeline_items.where(completed_at: nil).pluck(:pipeline_stage_id)
      FollowupCampaign.running.where(inbox_id: conversation.inbox_id, pipeline_stage_id: stage_ids).select { |campaign| campaign.running?(now) }
    end

    def self.update_deadline!(state:, conversation:, incoming:, now:)
      campaigns = campaigns_for(conversation, now: now)
      delays = campaigns.filter_map { |campaign| campaign.policy_object['debounce_ms'] if campaign.policy_object.valid? && campaign.policy['reclassification_enabled'] == true }
      generation = state.classification_generation + 1
      # If the same conversation is in several pipelines, wait for all their
      # configured quiet intervals; an inbound always invalidates immediately.
      deadline = incoming && delays.any? ? now + delays.max / 1000.0 : nil
      state.update!(classification_generation: generation, latest_incoming_message_id: incoming&.id, classification_due_at: deadline)
      [generation, deadline]
    end
    private_class_method :update_deadline!
  end
end
