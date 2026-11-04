module PipelineClassification
  # Normalize only the approved typed answer and bounded billing/audit metadata.
  module EvaluationResult
    private

    # Normalize the complete closed typed decision and bounded audit metadata at one boundary.
    def normalized_fields(snapshot, response) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      response = {} unless response.is_a?(Hash)
      fields = { status: 'abstained', reason: 'invalid_provider_schema', lease_expires_at: nil,
                 snapshot_hash: snapshot[:snapshot_hash], recommended_stage_id: nil, decision: {},
                 expires_at: [@row.expires_at, snapshot[:valid_until]].compact.min }
      fields[:input_tokens] = response[:input_tokens] if response[:usage_known] == true
      audit = latency_metadata
      if response[:served_model].is_a?(String) && response[:served_model].match?(%r{\A[a-zA-Z0-9._:/-]{1,160}\z})
        audit['served_model'] =
          response[:served_model]
      end
      if response[:cost_known] == true && response[:cost_usd].is_a?(Numeric) && response[:cost_usd].finite? && response[:cost_usd] >= 0
        audit['cost_usd'] =
          response[:cost_usd]
      end
      fields[:decision].merge!(audit)
      if response[:ok] == true && response[:model] == @row.model
        compiled = Catalog.from_revision(@row.pipeline_classification_catalog).compiled
        pipeline = response.dig(:answers, 'pipeline_candidate')
        stage = response.dig(:answers, 'stage_candidate')
        if typed_choice?(pipeline, compiled.dig('questions', 'pipeline_candidate')) &&
           typed_choice?(stage, compiled.dig('questions', 'stage_candidate'))
          pipeline_choice = pipeline.fetch('choice')
          stage_choice = stage.fetch('choice')
          pipeline_confidence = pipeline.fetch('confidence')
          stage_confidence = stage.fetch('confidence')
          thresholds = @row.pipeline_classification_catalog.snapshot.dig('classification', 'thresholds')
          fields[:decision].merge!('pipeline_choice' => pipeline_choice, 'pipeline_confidence' => pipeline_confidence,
                                   'choice' => stage_choice, 'confidence' => stage_confidence, 'financial_proof' => false)
          if pipeline_choice == 'no_candidate' || stage_choice == 'no_candidate'
            fields[:status] = 'classified'
            fields[:reason] = 'no_candidate'
          elsif pipeline_choice == 'unclear' || stage_choice == 'unclear' ||
                pipeline_confidence < thresholds.fetch('pipeline_candidate') || stage_confidence < thresholds.fetch('stage_candidate')
            fields[:reason] = 'uncertain_answer'
          else
            recommend!(fields, compiled, pipeline_choice, stage_choice)
          end
        end
      else
        fields[:reason] = response[:reason] if response[:reason].is_a?(String) && response[:reason].match?(/\A[a-z0-9_]{1,100}\z/)
        if response[:retryable] == true && @row.attempt_count < 2
          retry_after = response[:retry_after].is_a?(Numeric) ? response[:retry_after].clamp(1, 3600) : 5
          if now + retry_after.seconds < @row.expires_at
            fields[:status] = 'retryable_error'
            fields[:next_attempt_at] = now + retry_after.seconds
          end
        end
      end
      fields
    end

    def typed_choice?(answer, question)
      answer.is_a?(Hash) && question.is_a?(Hash) && answer['type'] == 'choice' &&
        question.fetch('criteria').key?(answer['choice']) && QuestionValidator.probability?(answer['confidence'])
    end

    def recommend!(fields, compiled, pipeline_choice, stage_choice)
      pipeline_id = compiled.fetch('pipeline_aliases')[pipeline_choice]
      stage_target = compiled.fetch('aliases')[stage_choice]
      return fields[:reason] = 'invalid_provider_schema' if pipeline_id.nil? || stage_target.nil?
      return fields[:reason] = 'pipeline_stage_mismatch' if stage_target.fetch('pipeline_id') != pipeline_id

      stage_id = stage_target.fetch('stage_id')
      fields[:decision].merge!('recommended_pipeline_id' => pipeline_id, 'recommended_stage_id' => stage_id)
      fields.merge!(status: 'classified', reason: 'stage_recommended', recommended_stage_id: stage_id)
    end

    def invoke_provider(client, snapshot, compiled)
      started = monotonic_now
      @provider_started = true
      client.call(state: snapshot.fetch(:state), questions: compiled.fetch('questions'), model: @row.model)
    ensure
      finished = monotonic_now if @provider_started
      if started && finished
        elapsed = (finished - started) * 1000.0
        @provider_latency_ms = elapsed if elapsed.finite? && elapsed >= 0
      end
    end

    def monotonic_now
      value = @monotonic_clock.call
      value if value.is_a?(Numeric) && value.finite? && value >= 0
    rescue StandardError
      nil
    end

    def latency_metadata
      @provider_latency_ms ? { 'provider_latency_ms' => @provider_latency_ms } : {}
    end
  end
end
