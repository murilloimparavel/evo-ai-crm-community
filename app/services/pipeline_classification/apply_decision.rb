module PipelineClassification
  # Apply only a fresh, high-confidence decision from an explicitly AUTO catalog.
  # The result row is the idempotency key and stores the complete application outcome.
  class ApplyDecision
    def initialize(result:)
      @result = result
    end

    def call
      ApplicationRecord.transaction { apply_locked }
    rescue ActiveRecord::RecordNotFound
      nil
    end

    private

    # Shared lock order with the evaluator: pipelines -> conversation -> state -> result -> card.
    def apply_locked # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      @result.reload
      return unless eligible_result?

      decision = @result.decision
      target_pipeline_id = decision['recommended_pipeline_id']
      lock_pipelines(target_pipeline_id)
      conversation = Conversation.lock.find_by(id: @result.conversation_id)
      return locked_skip!('conversation_unavailable') unless conversation

      state = PipelineClassificationState.lock.find_by(pipeline_id: @result.pipeline_id, conversation_id: conversation.id)
      @result.lock!
      return @result.decision['application'] if @result.decision['application'].present?
      return locked_skip!('state_unavailable') unless state
      return locked_skip!('stale_result') unless Evaluator.new(result: @result).current?

      catalog = Catalog.from_revision(@result.pipeline_classification_catalog)
      return locked_skip!('auto_mode_disabled') unless catalog.snapshot.dig('classification', 'mode') == 'auto'
      return locked_skip!('automatic_moves_paused') unless Budget.automatic_moves_authorized?
      return locked_skip!('catalog_not_current') unless catalog.current?

      apply_to_card(conversation, target_pipeline_id, decision)
    end

    def eligible_result?
      @result.status == 'classified' && @result.reason == 'stage_recommended'
    end

    def lock_pipelines(target_pipeline_id)
      ids = [@result.pipeline_id, target_pipeline_id].compact.uniq.sort
      Pipeline.where(id: ids).order(:id).lock.load
    end

    def apply_to_card(conversation, target_pipeline_id, decision) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      target_pipeline = Pipeline.find_by(id: target_pipeline_id, is_active: true)
      target_stage = target_pipeline&.pipeline_stages&.find_by(id: decision['recommended_stage_id'])
      return locked_skip!('target_unavailable') unless target_pipeline && target_stage

      item = PipelineItem.active.lock.find_by(conversation_id: conversation.id, pipeline_id: @result.pipeline_id)
      return locked_skip!('source_card_unavailable') unless item
      return locked_skip!('target_card_exists') if target_pipeline.id != item.pipeline_id &&
                                                   PipelineItem.active.exists?(conversation_id: conversation.id,
                                                                               pipeline_id: target_pipeline.id)
      return locked_skip!('stale_result') unless Evaluator.new(result: @result).current?

      record_movement(item, target_pipeline, target_stage)
    end

    def record_movement(item, target_pipeline, target_stage)
      details = {
        'from_pipeline_id' => item.pipeline_id,
        'from_stage_id' => item.pipeline_stage_id,
        'to_pipeline_id' => target_pipeline.id,
        'to_stage_id' => target_stage.id,
        'applied_at' => Time.current.iso8601
      }
      return record!('unchanged', nil, details) if item.pipeline_id == target_pipeline.id && item.pipeline_stage_id == target_stage.id
      return locked_skip!('move_rejected') unless item.move_by_pipeline_classification!(target_stage, result_id: @result.id)

      record!('applied', nil, details)
    end

    def locked_skip!(reason)
      record!('skipped', reason)
    end

    def record!(status, reason, details = {})
      outcome = { 'status' => status, 'reason' => reason }.merge(details)
      @result.update!(decision: @result.decision.merge('application' => outcome))
      outcome
    end
  end
end
