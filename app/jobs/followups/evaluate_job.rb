module Followups
  class EvaluateJob < ApplicationJob
    queue_as :scheduled_jobs

    def perform(execution_id)
      execution = FollowupExecution.find_by(id: execution_id)
      Evaluator.new(subject: execution).call if execution
    end
  end
end
