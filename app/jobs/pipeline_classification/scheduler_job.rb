module PipelineClassification
  class SchedulerJob < ApplicationJob
    queue_as :scheduled_jobs
    def perform
      now = Time.current
      Evaluator.retire_orphans!
      PipelineClassificationState.where('due_at <= ?', now).limit(100).find_each do |state|
        row = DebouncedClassifier.new(state: state, generation: state.generation, now: now).call
        EvaluateJob.perform_later(row.id) if row
      end
      PipelineClassificationResult.joins(:pipeline, :conversation, :pipeline_classification_catalog)
        .where(status: %w[reserved retryable_error evaluating])
        .where('next_attempt_at IS NULL OR next_attempt_at <= ?', now)
        .where('lease_expires_at IS NULL OR lease_expires_at <= ?', now).limit(100).find_each do |result|
          EvaluateJob.perform_later(result.id)
        end
    end
  end
end
