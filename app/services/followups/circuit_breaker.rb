require 'time'

module Followups
  # Installation-wide provider state contains only counters and safe reason
  # codes. No provider responses, prompts, credentials or customer data.
  class CircuitBreaker
    NAME = 'FOLLOWUP_PROVIDER_STATE'.freeze
    class Open < StandardError; end

    def initialize(settings: nil)
      @settings = settings || InstallationConfig.find_by(name: 'FOLLOWUP_SETTINGS')&.value || {}
      @settings = @settings.is_a?(Hash) ? @settings.stringify_keys : {}
    end

    def check!(now: Time.current)
      configuration!
      row = InstallationConfig.find_by(name: NAME)
      return true unless row

      state = state!(row)
      raise Open, 'provider_manual_reset_required' if state['manual_reset_required']
      until_time = parse_time(state['open_until'])
      raise Open, 'provider_circuit_open' if until_time && until_time > now
      true
    end

    def record(result:, campaign: nil, model: nil, questions: nil, now: Time.current)
      reason = result.is_a?(Hash) ? result[:reason] : nil
      failed = failure_reason?(reason)
      success = provider_success?(result, campaign, model: model, questions: questions)
      return unless failed || success

      threshold, cooldown = configuration!
      row = InstallationConfig.create_or_find_by!(name: NAME) { |config| config.value = initial_state }
      row.with_lock do
        state = state!(row)
        # A success from another request already in flight must never reopen an
        # integration paused by a 401. Only the explicit operator reset does.
        next if state['manual_reset_required'] && reason != 'provider_http_401'

        if failed
          count = state['consecutive_failures'] + 1
          state.merge!('consecutive_failures' => count, 'last_reason' => reason, 'last_failure_at' => now.iso8601(6))
          if reason == 'provider_http_401'
            state['manual_reset_required'] = true
            state['open_until'] = nil
          elsif count >= threshold
            state['open_until'] = (now + cooldown.seconds).iso8601(6)
          end
        else
          state.merge!('consecutive_failures' => 0, 'open_until' => nil, 'last_reason' => nil)
        end
        row.update!(value: state)
      end
      nil
    end

    def reset!(actor:, now: Time.current)
      unless actor.is_a?(User) && actor.persisted? && actor.has_permission?('installation_configs.manage')
        raise Open, 'provider_reset_operator_required'
      end
      row = InstallationConfig.create_or_find_by!(name: NAME) { |config| config.value = initial_state }
      row.with_lock do
        state = initial_state.merge('reset_by_user_id' => actor.id, 'reset_at' => now.iso8601(6))
        row.update!(value: state)
      end
      true
    end

    private

    def initial_state
      { 'consecutive_failures' => 0, 'open_until' => nil, 'manual_reset_required' => false }
    end

    def configuration!
      threshold = @settings.fetch('circuit_failure_threshold', 5)
      cooldown = @settings.fetch('circuit_cooldown_seconds', 300)
      unless threshold.is_a?(Integer) && threshold.between?(1, 100) && cooldown.is_a?(Integer) && cooldown.between?(1, 86_400)
        raise Open, 'provider_circuit_configuration_invalid'
      end
      [threshold, cooldown]
    end

    def state!(row)
      state = row.value
      unless state.is_a?(Hash) && state['consecutive_failures'].is_a?(Integer) && state['consecutive_failures'] >= 0 && [true, false].include?(state['manual_reset_required']) && (state['open_until'].nil? || parse_time(state['open_until']))
        raise Open, 'provider_circuit_state_invalid'
      end
      state.stringify_keys
    end

    def parse_time(value)
      return nil if value.nil?
      raise Open, 'provider_circuit_state_invalid' unless value.is_a?(String) && value.bytesize <= 40

      Time.iso8601(value)
    rescue ArgumentError
      raise Open, 'provider_circuit_state_invalid'
    end

    def failure_reason?(reason)
      reason.is_a?(String) && (%w[classification_transport_error classification_timeout invalid_provider_schema].include?(reason) || reason.match?(/\Aprovider_http_[1-5]\d{2}\z/))
    end

    def provider_success?(result, campaign, model: nil, questions: nil)
      expected_model = model || campaign&.policy&.dig('classifier', 'model')
      return false unless [Ai::JevClient::MODEL, Ai::JevClient::OPENROUTER_MODEL].include?(expected_model)
      return false unless result.is_a?(Hash) && result[:model] == expected_model && result[:usage_known] == true && result[:input_tokens].is_a?(Integer) && result[:input_tokens] >= 0
      return false if result.key?(:cost_known) && result[:cost_known] != true
      answers = result[:classification]
      questions ||= campaign&.policy&.dig('classifier', 'questions')
      return false unless answers.is_a?(Hash) && questions.is_a?(Hash) && answers.keys.sort == questions.keys.sort

      questions.all? do |key, question|
        answer = answers[key]
        next false unless answer.is_a?(Hash) && answer['type'] == question['type'] && (answer.keys - %w[type choice confidence noul score probabilities]).empty?
        if question['type'] == 'noul'
          next probability?(answer['noul'])
        end
        keys = question['type'] == 'score' ? question['criteria'].each_index.map(&:to_s) : question['criteria'].keys
        probabilities = answer['probabilities']
        next false unless probability?(answer['confidence']) && probabilities.is_a?(Hash) && probabilities.keys.sort == keys.sort && probabilities.values.all? { |value| probability?(value) } && (probabilities.values.sum - 1).abs <= 0.001
        if question['type'] == 'score'
          score = answer['score']
          score.is_a?(Numeric) && score.finite? && score.between?(0, keys.length - 1)
        else
          keys.include?(answer['choice'])
        end
      end
    rescue NoMethodError, TypeError, ArgumentError
      false
    end

    def probability?(value)
      value.is_a?(Numeric) && value.finite? && value.between?(0, 1)
    end
  end
end
