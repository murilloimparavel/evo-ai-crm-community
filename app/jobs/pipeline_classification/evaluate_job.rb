module PipelineClassification
  class EvaluateJob < ApplicationJob
    queue_as :scheduled_jobs
    def perform(id)
      result = PipelineClassificationResult.find_by(id: id)
      Evaluator.new(result: result).call if result
    end
  end
end
