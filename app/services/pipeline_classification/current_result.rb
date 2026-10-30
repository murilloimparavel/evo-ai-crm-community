module PipelineClassification
  class CurrentResult
    def self.call(pipeline:, conversation:, now: Time.current)
      return unless pipeline && conversation

      PipelineClassificationResult.where(pipeline_id: pipeline.id, conversation_id: conversation.id, status: 'classified')
                                  .order(created_at: :desc).limit(3).detect do |row|
        Evaluator.new(result: row, now: now).current?
      end
    rescue Catalog::Invalid, ActiveRecord::RecordNotFound
      nil
    end
  end
end
