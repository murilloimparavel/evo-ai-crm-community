module PipelineClassification
  # Closed aggregate schema; errors never include provider or customer values.
  module ProfileValidation
    private

    # Reject every incompatible aggregate field before any persisted profile changes.
    def validate_profile!(profile) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      unless profile['schema_version'] == 1 && profile['model'] == Catalog::MODEL && profile['question_version'] == 'pipeline_stage_v1'
        invalid!('unsupported schema or model')
      end
      invalid!('enabled/mode mismatch') unless [true,
                                                false].include?(profile['enabled']) && %w[off
                                                                                          observe].include?(profile['mode']) &&
                                               profile['enabled'] == (profile['mode'] == 'observe')
      text!(profile['purpose'], allow_empty: !profile['enabled'])
      { 'debounce_ms' => 250..300_000, 'snapshot_ttl_seconds' => 30..3600, 'result_ttl_seconds' => 30..3600 }.each do |key, range|
        invalid!("invalid #{key}") unless profile[key].is_a?(Integer) && range.cover?(profile[key])
      end
      inboxes = profile['inbox_ids']
      unless inboxes.is_a?(Array) && inboxes.size <= 50 && inboxes.uniq.size == inboxes.size && inboxes.all?(String) &&
             Inbox.where(id: inboxes).count == inboxes.length
        invalid!('invalid inbox scope')
      end
      invalid!('inbox scope required') if profile['enabled'] && inboxes.empty?
      invalid!('invalid thresholds') unless profile['thresholds'].is_a?(Hash) && profile['thresholds'].keys == ['stage_candidate'] &&
                                            Followups::QuestionValidator.probability?(profile.dig(
                                                                                        'thresholds', 'stage_candidate'
                                                                                      ))
      invalid!('invalid context_sources') unless profile['context_sources'].is_a?(Hash) && (profile['context_sources'].keys - ['fields']).empty?
      Followups::SnapshotContext.validate!(profile['context_sources'])
    rescue Followups::SnapshotContext::Invalid
      invalid!('invalid context_sources')
    end

    # Reject every incompatible aggregate field before any persisted profile changes.
    def validate_sources!(profile) # rubocop:disable Metrics/CyclomaticComplexity
      profile['context_sources'].fetch('fields', []).each do |selection|
        model = selection['source'] == 'conversation.custom_attributes' ? 'conversation_attribute' : 'contact_attribute'
        definition = CustomAttributeDefinition.find_by(attribute_model: model, attribute_key: selection['field'])
        expected_type = selection['type'] == 'boolean' ? 'checkbox' : 'list'
        invalid!('unknown or incompatible context field') unless definition && definition.attribute_display_type == expected_type
        if (selection['type'] == 'enum') && !(selection['allowed_values'] - Array(definition.attribute_values)).empty?
          invalid!('unknown context enum value')
        end
      end
    end

    def validate_stage!(profile)
      invalid!('classification_enabled must be boolean') unless [true, false].include?(profile['classification_enabled'])
      text!(profile['definition'], allow_empty: !profile['classification_enabled'])
      Catalog::CRITERIA.each do |key|
        invalid!("invalid #{key}") unless profile[key].is_a?(Array) && profile[key].size <= Catalog::LIMITS[:max_criteria]
        profile[key].each { |value| text!(value) }
      end
    end

    def text!(value, allow_empty: false)
      if value.is_a?(String) && value.valid_encoding? && value.length <= Catalog::LIMITS[:max_text_length] && (allow_empty || value.strip.present?)
        return
      end

      invalid!('invalid or oversized text')
    end

    def unknown!(value, keys, name)
      invalid!("unsupported #{name} keys") unless (value.keys - keys).empty?
    end

    def invalid!(message)
      raise Catalog::Invalid, message
    end
  end
end
