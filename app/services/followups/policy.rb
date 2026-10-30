module Followups
  # Configuration is data. No executable expressions, destinations or free-form
  # callbacks are accepted. Missing settings fail closed.
  class Policy
    ROOT_KEYS = %w[
      timezone debounce_ms reclassification_enabled snapshot_limits snapshot_context contact_window steps
      max_lateness_minutes authorization_ttl_seconds cooldown_minutes allowed_statuses blocking_label_ids
      opt_out_label_ids consent_label_ids label_bindings channel_authorization cohort classifier classification_source limits approvals
    ].freeze
    NESTED_KEYS = {
      'contact_window' => %w[start end weekdays],
      'channel_authorization' => %w[provider approved window_seconds template_required template_name template_language template_namespace],
      'cohort' => %w[salt percentage],
      'classifier' => %w[model question_version questions conditions],
      'limits' => %w[daily_conversations daily_usd max_attempts max_billable_tokens_per_attempt billing_ceiling_verified],
      'approvals' => %w[templates_reviewed privacy_reviewed retention_days language_validated]
    }.freeze
    attr_reader :data

    def initialize(data)
      @data = data.is_a?(Hash) ? data.deep_stringify_keys : {}
    end

    def [](key)
      data[key.to_s]
    end

    # Keep the complete closed policy schema and validation error precedence intact during release formatting.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def errors
      result = []
      result << 'unknown fields' if (data.keys - ROOT_KEYS).any?
      NESTED_KEYS.each do |key, allowed|
        next if key == 'classifier' && pipeline_catalog?

        value = data[key]
        result << "#{key} must be an object" unless value.is_a?(Hash)
        result << "#{key} has unknown fields" if value.is_a?(Hash) && (value.keys - allowed).any?
      end
      if data.key?('classification_source') && !(self['classification_source'] == { 'type' => 'pipeline_catalog' } && !data.key?('classifier'))
        result << 'classification_source must select pipeline_catalog without duplicate classifier settings'
      end
      result << 'timezone must be an IANA zone' unless TZInfo::Timezone.all_identifiers.include?(self['timezone'])
      result << 'debounce_ms must be between 100 and 300000' unless integer_between?(self['debounce_ms'], 100, 300_000)
      result << 'reclassification_enabled must be boolean' unless [true, false].include?(self['reclassification_enabled'])
      if data.key?('snapshot_context')
        begin
          SnapshotContext.validate!(self['snapshot_context'])
        rescue SnapshotContext::Invalid
          result << 'snapshot_context must select bounded typed CRM facts from allowed sources'
        end
      end
      if data.key?('snapshot_limits')
        snapshot = self['snapshot_limits']
        ceilings = { 'max_messages' => 16, 'max_message_characters' => 4000, 'max_request_bytes' => 12 * 1024 }
        unless snapshot.is_a?(Hash) && (snapshot.keys - ceilings.keys).empty? && snapshot.all? do |key, value|
          integer_between?(value, 1, ceilings.fetch(key))
        end
          result << 'snapshot_limits must use bounded message, character and byte limits'
        end
      end
      %w[max_lateness_minutes authorization_ttl_seconds cooldown_minutes].each do |key|
        result << "#{key} must be a positive integer" unless integer_between?(self[key], 1, 525_600)
      end
      %w[blocking_label_ids opt_out_label_ids consent_label_ids].each do |key|
        result << "#{key} must be an array of UUIDs" unless self[key].is_a?(Array) && self[key].all? do |id|
          id.is_a?(String) && id.match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i)
        end
      end
      label_ids = %w[blocking_label_ids opt_out_label_ids consent_label_ids].flat_map { |key| self[key].is_a?(Array) ? self[key] : [] }.uniq
      bindings = self['label_bindings']
      unless bindings.is_a?(Hash) && label_ids.all?(String) && bindings.keys.sort == label_ids.sort && bindings.values.all? do |title|
        title.is_a?(String) && title.present? && title.length <= 128
      end
        result << 'label_bindings must bind every configured label UUID to its approved title'
      end
      statuses = self['allowed_statuses']
      result << 'allowed_statuses must contain only open/pending' unless statuses.is_a?(Array) && statuses.any? && (statuses - %w[open
                                                                                                                                  pending]).empty?
      window = object('contact_window')
      result << 'contact_window requires HH:MM times' unless [window['start'], window['end']].all? do |value|
        value.is_a?(String) && value.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)
      end && window['start'] < window['end']
      result << 'contact_window weekdays must be 0..6' unless window['weekdays'].is_a?(Array) && window['weekdays'].any? &&
                                                              window['weekdays'].all? do |day|
                                                                integer_between?(day, 0, 6)
                                                              end
      result << 'steps require stable IDs, delays and template IDs' unless steps_valid?
      classifier = object('classifier')
      unless pipeline_catalog? || (classifier['model'].is_a?(String) && classifier['model'].present? &&
        classifier['question_version'].is_a?(String) && classifier['question_version'].present? &&
          classifier['questions'].is_a?(Hash) && classifier['questions'].any? && classifier['conditions'].is_a?(Array) &&
            classifier['conditions'].any?)
        result << 'classifier must have model, question_version, questions and conditions'
      end
      begin
        unless pipeline_catalog?
          QuestionValidator.call(classifier['questions'])
          DecisionRules.new(questions: classifier['questions'], conditions: classifier['conditions'])
        end
      rescue QuestionValidator::Invalid, DecisionRules::Invalid
        result << 'classifier questions or conditions are invalid'
      end
      limits = object('limits')
      %w[daily_conversations max_attempts max_billable_tokens_per_attempt].each do |key|
        result << "limits.#{key} must be positive" unless integer_between?(limits[key], 1, 1_000_000)
      end
      result << 'max_attempts must be <=2' if limits['max_attempts'].to_i > 2
      result << 'daily_usd must be positive' unless positive_number?(limits['daily_usd'])
      cohort = object('cohort')
      result << 'cohort requires stable salt and percentage' unless cohort['salt'].is_a?(String) && cohort['salt'].present? && integer_between?(
        cohort['percentage'], 0, 100
      )
      channel = object('channel_authorization')
      valid_channel = channel['provider'].is_a?(String) && [true, false].include?(channel['approved']) &&
                      [true, false].include?(channel['template_required']) &&
                      integer_between?(channel['window_seconds'], 1, 31_536_000)
      result << 'channel authorization requires provider and booleans' unless valid_channel
      result
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    def valid?
      errors.empty?
    end

    def within_window?(now)
      return false unless valid?

      local = now.in_time_zone(self['timezone'])
      window = self['contact_window']
      window['weekdays'].include?(local.wday) && local.strftime('%H:%M') >= window['start'] && local.strftime('%H:%M') < window['end']
    end

    def next_window(now)
      return nil unless valid?
      return now if within_window?(now)

      local = now.in_time_zone(self['timezone'])
      8.times do |offset|
        date = local.to_date + offset
        next unless self['contact_window']['weekdays'].include?(date.wday)

        candidate = Time.find_zone!(self['timezone']).parse("#{date.iso8601} #{self['contact_window']['start']}")
        return candidate if candidate > now
      end
      nil
    end

    private

    def pipeline_catalog?
      self['classification_source'] == { 'type' => 'pipeline_catalog' }
    end

    def object(key)
      self[key].is_a?(Hash) ? self[key] : {}
    end

    def integer_between?(value, lower, upper)
      value.is_a?(Integer) && value.between?(lower, upper)
    end

    def positive_number?(value)
      value.is_a?(Numeric) && value.finite? && value.positive?
    end

    # Keep the complete closed policy schema and validation error precedence intact during release formatting.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def steps_valid?
      steps = self['steps']
      steps.is_a?(Array) && steps.any? && steps.length <= 10 && steps.all? do |step|
        step.is_a?(Hash) && (step.keys - %w[step_id delay_minutes
                                            template_id]).empty? && step['step_id'].is_a?(String) &&
          step['step_id'].present? && integer_between?(step['delay_minutes'], 1,
                                                       525_600) && step['template_id'].is_a?(String) && step['template_id'].present?
      end && steps.pluck('step_id').uniq.length == steps.length
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  end
end
