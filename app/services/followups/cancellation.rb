module Followups
  class Cancellation
    def self.invalidate(conversation:, reason:, now: Time.current)
      conversation.with_lock do
        state = FollowupConversationState.for!(conversation)
        state.lock!
        state.update!(revision: state.revision + 1, active_execution_id: nil)
        FollowupExecution.where(conversation_id: conversation.id, status: FollowupExecution::PENDING)
                         .update_all(status: 'cancelled', reason: reason, finalized_at: now, updated_at: now)
        FollowupClassification.where(conversation_id: conversation.id, status: %w[reserved evaluating retryable_error])
                              .update_all(status: 'cancelled', reason: reason, updated_at: now)
        state
      end
    end
  end
end
