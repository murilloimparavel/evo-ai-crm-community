module Followups
  class ClassificationRetryJob < ApplicationJob
    queue_as :scheduled_jobs

    def perform(classification_id)
      row = FollowupClassification.find_by(id: classification_id)
      Evaluator.new(subject: row).call if row
    end
  end
end
