module Followups
  class SchedulerJob < ApplicationJob
    queue_as :scheduled_jobs
    BATCH_SIZE = 100

    def perform
      now = Time.current
      Retention.retire_orphans!(now: now)
      FollowupConversationState.where('classification_due_at <= ?', now).limit(BATCH_SIZE).find_each do |state|
        DebouncedClassificationJob.perform_later(state.conversation_id, state.classification_generation)
      end
      FollowupClassification.where(status: %w[reserved retryable_error]).where('next_attempt_at IS NULL OR next_attempt_at <= ?', now).limit(BATCH_SIZE).find_each do |row|
        ClassificationRetryJob.perform_later(row.id)
      end
      FollowupExecution.where(status: %w[reserved retryable_error]).where('due_at <= ?', now).where('next_attempt_at IS NULL OR next_attempt_at <= ?', now).limit(BATCH_SIZE).find_each do |row|
        EvaluateJob.perform_later(row.id)
      end
      ReconcileJob.perform_later
    end
  end
end
