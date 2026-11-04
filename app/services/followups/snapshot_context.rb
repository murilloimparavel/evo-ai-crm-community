# frozen_string_literal: true

module Followups
  # Selects only named, closed CRM facts. No raw attributes, interpolation,
  # caller-supplied object paths, Ruby or SQL can cross this boundary.
  class SnapshotContext
    class Invalid < StandardError; end
    class InvalidValue < StandardError; end
    SOURCES = %w[conversation.custom_attributes contact.custom_attributes].freeze
    TOKEN = /\A[a-z][a-z0-9_]{0,63}\z/
    MAX_FIELDS = 8
    REQUIRED_FIELD_KEYS = %w[key source field type].freeze
    FIELD_TYPES = %w[boolean enum].freeze

    def self.validate!(config)
      new(config)
      true
    end

    def initialize(config)
      @config = config
      validate!
    end

    # Validate the closed typed source allowlist and every selected value before exposing minimized CRM context.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def call(conversation:)
      result = {}
      result['stage'] = @config['stage_key'] if @config.key?('stage_key')
      @config.fetch('fields', []).each do |selection|
        record = selection['source'] == 'conversation.custom_attributes' ? conversation : conversation.contact
        raise InvalidValue, 'invalid_crm_context_value' unless record

        attributes = record.custom_attributes
        raise InvalidValue, 'invalid_crm_context_value' unless attributes.nil? || attributes.is_a?(Hash)

        attributes ||= {}
        next unless attributes.key?(selection['field'])

        value = attributes[selection['field']]
        next if value.nil?

        valid = if selection['type'] == 'boolean'
                  value == true || value == false
                else
                  value.is_a?(String) && selection['allowed_values'].include?(value)
                end
        raise InvalidValue, 'invalid_crm_context_value' unless valid

        result[selection['key']] = value
      end
      result
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    private

    def token?(value)
      value.is_a?(String) && TOKEN.match?(value)
    end

    # Validate the closed typed source allowlist and every selected value before exposing minimized CRM context.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def validate!
      invalid! unless @config.is_a?(Hash) && (@config.keys - %w[stage_key fields]).empty?
      invalid! if @config.key?('stage_key') && !token?(@config['stage_key'])
      fields = @config.fetch('fields', [])
      invalid! unless fields.is_a?(Array) && fields.length <= MAX_FIELDS
      keys = []
      fields.each do |field|
        invalid! unless field.is_a?(Hash) && (field.keys - %w[key source field type allowed_values]).empty?
        invalid! unless REQUIRED_FIELD_KEYS.all? { |key| field.key?(key) }
        invalid! unless token?(field['key']) && field['key'] != 'stage' && token?(field['field'])
        invalid! unless SOURCES.include?(field['source']) && FIELD_TYPES.include?(field['type'])
        if field['type'] == 'enum'
          values = field['allowed_values']
          invalid! unless values.is_a?(Array) && values.size.between?(1, 16) && values.uniq.size == values.size && values.all? do |value|
            token?(value)
          end
        elsif field.key?('allowed_values')
          invalid!
        end
        keys << field['key']
      end
      invalid! unless keys.uniq.length == keys.length
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    def invalid!
      raise Invalid, 'invalid_snapshot_context'
    end
  end
end
