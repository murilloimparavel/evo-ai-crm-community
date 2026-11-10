module PipelineClassification
  class ApplyDecisionJob < ApplicationJob
    queue_as :pipeline_classification

    def perform(id)
      result = PipelineClassificationResult.find_by(id: id)
      ApplyDecision.new(result: result).call if result
    end
  end
end
