module PipelineClassification
  class RuntimeSettings
    FIELDS = %i[
      online_enabled privacy_reviewed language_validated billing_ceiling_verified automatic_moves_enabled
      max_attempt_cost_usd daily_usd daily_conversations budget_timezone retention_days
      circuit_failure_threshold circuit_cooldown_seconds
    ].freeze
    APPROVAL_FIELDS = %w[online_enabled privacy_reviewed language_validated billing_ceiling_verified].freeze
    BOOLEAN_FIELDS = (APPROVAL_FIELDS + ['automatic_moves_enabled']).freeze
    BOOLEAN_VALUES = [true, false].freeze
    NUMERIC_RANGES = { 'max_attempt_cost_usd' => 0.001..0.05, 'daily_usd' => 0.01..1000 }.freeze
    INTEGER_RANGES = { 'daily_conversations' => 1..10_000, 'retention_days' => 1..3650,
                       'circuit_failure_threshold' => 1..100, 'circuit_cooldown_seconds' => 1..86_400 }.freeze

    def initialize(settings:, updated_keys:)
      @settings = settings.deep_stringify_keys
      @updated_keys = updated_keys
    end

    def validate!
      validate_booleans!
      validate_numeric_ranges!
      validate_integer_ranges!
      validate_timezone!
      validate_online_authorization!
      @settings
    end

    def self.public_settings(settings)
      settings.slice(*(FIELDS.map(&:to_s) - ['automatic_moves_enabled']))
    end

    def self.authorized?(settings)
      new(settings: settings, updated_keys: []).authorized?
    end

    def authorized?
      authorized_settings?
    end

    private

    def validate_booleans!
      @updated_keys.each do |key|
        next unless BOOLEAN_FIELDS.include?(key)
        raise Catalog::Invalid, "#{key}_must_be_boolean" unless BOOLEAN_VALUES.include?(@settings[key])
      end
    end

    def validate_numeric_ranges!
      NUMERIC_RANGES.each do |key, range|
        next unless @updated_keys.include?(key)

        value = @settings[key]
        valid = value.is_a?(Numeric) && value.finite? && range.cover?(value)
        raise Catalog::Invalid, "#{key}_out_of_range" unless valid
      end
    end

    def validate_integer_ranges!
      INTEGER_RANGES.each do |key, range|
        next unless @updated_keys.include?(key)
        raise Catalog::Invalid, "#{key}_out_of_range" unless @settings[key].is_a?(Integer) && range.cover?(@settings[key])
      end
    end

    def validate_timezone!
      return unless @updated_keys.include?('budget_timezone')
      return if TZInfo::Timezone.all_identifiers.include?(@settings['budget_timezone'])

      raise Catalog::Invalid, 'budget_timezone_invalid'
    end

    def validate_online_authorization!
      return unless @settings['online_enabled'] == true || @settings['automatic_moves_enabled'] == true
      raise Catalog::Invalid, 'provider_credential_required' unless Ai::DecisionClient.status[:configured]
      raise Catalog::Invalid, 'online_authorization_and_budget_required' unless authorized_settings?
    end

    def authorized_settings?
      budget_ready? && APPROVAL_FIELDS.all? { |key| @settings[key] == true }
    end

    def budget_ready?
      valid_numeric_settings? && valid_daily_limits? && TZInfo::Timezone.all_identifiers.include?(@settings['budget_timezone'])
    end

    def valid_numeric_settings?
      NUMERIC_RANGES.all? do |key, range|
        value = @settings[key]
        value.is_a?(Numeric) && value.finite? && range.cover?(value)
      end
    end

    def valid_daily_limits?
      required_ranges = INTEGER_RANGES.except('circuit_failure_threshold', 'circuit_cooldown_seconds')
      required_ranges.all? do |key, range|
        @settings[key].is_a?(Integer) && range.cover?(@settings[key])
      end
    end
  end
end
