module Followups
  # Reuses a valid decision; this adapter never calls a provider or moves a card.
  class CatalogClassifier
    def initialize(campaign:, subject:)
      @campaign = campaign
      @subject = subject
    end

    # Retain the shared adapter keyword interface even when this implementation does not consume every argument.
    # rubocop:disable Lint/UnusedMethodArgument
    def classify(snapshot:, policy:)
      # rubocop:enable Lint/UnusedMethodArgument
      row = PipelineClassification::CurrentResult.call(pipeline: @campaign.pipeline_stage&.pipeline, conversation: @subject.conversation)
      metadata = @campaign.classifier_config
      result = { action: 'abstain', reason: 'pipeline_classification_unavailable', model: metadata['model'],
                 question_version: metadata['question_version'], usage_known: true, input_tokens: 0, cost_known: true, cost_usd: 0 }
      return result unless row && row.recommended_stage_id == @campaign.pipeline_stage_id

      step = @campaign.policy['steps'].find { |entry| entry['step_id'] == @subject.step_id } if @subject.respond_to?(:step_id)
      return result unless step

      result.merge(action: 'send', reason: 'pipeline_classification_current', template_id: step['template_id'],
                   pipeline_classification_result_id: row.id, classification_catalog_hash: row.catalog_hash)
    end
  end
end
