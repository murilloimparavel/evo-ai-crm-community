module Followups
  # Pure response checks and provider failure accounting, outside claim/finalization locks.
  module EvaluatorResultHandling
    CONFIDENCE_TYPES = %w[choice score].freeze

    private

    def campaign
      @subject.followup_campaign
    end

    def record_unexpected_provider_failure
      CircuitBreaker.new.record(result: { reason: 'classification_transport_error' }, campaign: campaign, now: now)
    rescue StandardError
      # A failed breaker persistence must still leave the execution closed and
      # its unknown-usage reservation intact; never retry the provider here.
      nil
    end

    def execution?
      @subject.is_a?(FollowupExecution)
    end

    # Validate and sanitize the complete closed provider response before any downstream decision is accepted.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def normalize(result)
      return { action: 'abstain', reason: 'invalid_classifier_result' } unless result.is_a?(Hash)

      config = campaign.classifier_config
      valid = %w[send block
                 abstain].include?(result[:action]) && result[:reason].is_a?(String) &&
              result[:reason].match?(/\A[a-z0-9_]{1,100}\z/) && result[:model] == config['model'] &&
              result[:question_version] == config['question_version']
      valid &&= [true,
                 false].include?(result[:usage_known]) && (result[:usage_known] == false ||
                   (result[:input_tokens].is_a?(Integer) && result[:input_tokens] >= 0))
      return { action: 'abstain', reason: 'invalid_classifier_result' } unless valid

      if result[:action] == 'send'
        ids = campaign.policy['steps'].pluck('template_id')
        return { action: 'abstain', reason: 'invalid_template_selection' } unless ids.include?(result[:template_id])
      end
      result
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    # Validate and sanitize the complete closed provider response before any downstream decision is accepted.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def sanitized_answers(answers)
      questions = campaign.classifier_config['questions'] || {}
      answers.each_with_object({}) do |(key, value), clean|
        next unless questions.key?(key.to_s) && value.is_a?(Hash)

        question = questions[key.to_s]
        typed = value.stringify_keys.slice('type', 'choice', 'confidence', 'noul', 'score', 'probabilities')
        clean[key.to_s] = typed.select do |field, item|
          case field
          when 'type' then item == question['type']
          when 'choice' then question['type'] == 'choice' && item.is_a?(String) && question['criteria'].is_a?(Hash) && question['criteria'].key?(item)
          when 'confidence' then CONFIDENCE_TYPES.include?(question['type']) && probability?(item)
          when 'noul' then question['type'] == 'noul' && probability?(item)
          when 'score' then question['type'] == 'score' && question['criteria'].is_a?(Array) && item.is_a?(Numeric) &&
            item.finite? && item.between?(0, question['criteria'].length - 1)
          when 'probabilities' then valid_probabilities?(item, question)
          else false
          end
        end
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    def probability?(value)
      value.is_a?(Numeric) && value.finite? && value.between?(0, 1)
    end

    # Validate and sanitize the complete closed provider response before any downstream decision is accepted.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def valid_probabilities?(value, question)
      keys = if question['type'] == 'choice' && question['criteria'].is_a?(Hash)
               question['criteria'].keys
             elsif question['type'] == 'score' && question['criteria'].is_a?(Array)
               question['criteria'].each_index.map(&:to_s)
             end
      keys && value.is_a?(Hash) && value.keys.sort == keys.sort && value.values.all? do |number|
        probability?(number)
      end && (value.values.sum - 1).abs <= 0.001
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  end
end
