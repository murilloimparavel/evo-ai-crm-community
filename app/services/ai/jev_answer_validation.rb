module Ai
  # Mathematical invariants for each typed System One response shape.
  module JevAnswerValidation
    private

    # Validate the complete closed answer shape and probability invariants in one boundary.
    def validate_answer!(answer, question) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      raise JevClient::Invalid unless answer.is_a?(Hash) && answer['type'] == question['type']

      if question['type'] == 'noul'
        raise JevClient::Invalid unless answer.keys.sort == %w[noul type] && probability?(answer['noul'])

        return
      end

      score = question['type'] == 'score'
      fields = score ? %w[confidence legend probabilities score type] : %w[choice confidence probabilities type]
      raise JevClient::Invalid unless answer.keys.sort == fields && probability?(answer['confidence'])

      keys = score ? question['criteria'].each_index.map(&:to_s) : question['criteria'].keys
      distribution = answer['probabilities']
      raise JevClient::Invalid unless distribution.is_a?(Hash) && distribution.keys.sort == keys.sort
      raise JevClient::Invalid unless distribution.values.all? { |value| probability?(value) }
      raise JevClient::Invalid unless (distribution.values.sum - 1.0).abs <= 0.001

      if score
        value = answer['score']
        raise JevClient::Invalid unless value.is_a?(Numeric) && value.finite? && value.between?(0, keys.length - 1)

        expected = distribution.sum { |level, probability| level.to_i * probability }
        raise JevClient::Invalid unless (value - expected).abs <= 0.02
        raise JevClient::Invalid unless answer['legend'] == question['criteria'].each_with_index.to_h { |item, index| [index.to_s, item] }

        modal = distribution.max_by { |_level, probability| probability }.first.to_i
        uniform_mad = keys.sum { |level| (level.to_i - ((keys.length - 1) / 2.0)).abs } / keys.length
        distance = distribution.sum { |level, probability| probability * (level.to_i - modal).abs }
        expected_confidence = [0.0, 1.0 - (distance / uniform_mad)].max
      else
        raise JevClient::Invalid unless keys.include?(answer['choice'])
        raise JevClient::Invalid unless distribution[answer['choice']] == distribution.values.max

        expected_confidence = (distribution.values.max - (1.0 / keys.length)) / (1.0 - (1.0 / keys.length))
      end
      raise JevClient::Invalid unless (answer['confidence'] - expected_confidence).abs <= 0.02
    end

    def probability?(number)
      number.is_a?(Numeric) && number.finite? && number.between?(0, 1)
    end
  end
end
