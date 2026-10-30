require 'bigdecimal'

module PipelineClassification
  class Budget < Followups::Budget
    def self.settings
      value = InstallationConfig.find_by(name: 'PIPELINE_CLASSIFICATION_SETTINGS')&.value
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end

    def self.installation_authorized?
      settings = self.settings
      %w[online_enabled privacy_reviewed language_validated billing_ceiling_verified].all? { |key| settings[key] == true } &&
        settings['retention_days'].is_a?(Integer) && settings['retention_days'].positive? &&
        settings['max_attempt_cost_usd'].is_a?(Numeric) && settings['max_attempt_cost_usd'].finite? && settings['max_attempt_cost_usd'].positive?
    end

    def initialize(offline: false, settings: nil)
      super
      @pipeline_authorization = nil
    end

    def reserve!(subject:, catalog:, now: Time.current)
      @pipeline_authorization = nil
      shared = current_settings
      Followups::CircuitBreaker.new(settings: shared).check!(now: now)
      raise Exceeded, 'online_approvals_required' unless @offline || self.class.installation_authorized?
      limits = self.class.settings
      ceiling = limits['max_attempt_cost_usd']
      raise Exceeded, 'verified_attempt_ceiling_required' unless ceiling.is_a?(Numeric) && ceiling.finite? && ceiling.positive?
      zone = shared['budget_timezone']
      raise Exceeded, 'budget_timezone_required' unless TZInfo::Timezone.all_identifiers.include?(zone)
      daily = shared['daily_usd']
      count = shared['daily_conversations']
      raise Exceeded, 'installation_budget_required' unless daily.is_a?(Numeric) && daily.finite? && daily.positive? && count.is_a?(Integer) && count.positive?
      raise Exceeded, 'attempt_limit' if subject.attempt_count >= 2
      day = FollowupBudgetDay.create_or_find_by!(scope_key: 'installation', budget_date: now.in_time_zone(zone).to_date) { |row| row.timezone = zone }
      reservation = nil
      day.with_lock do
        raise Exceeded, 'budget_timezone_changed' unless day.timezone == zone
        amount = BigDecimal(ceiling.to_s)
        raise Exceeded, 'daily_cost_limit' if day.reserved_usd + day.spent_usd + amount > BigDecimal(daily.to_s)
        ids = day.conversation_ids.dup
        unless ids.include?(subject.conversation_id)
          raise Exceeded, 'daily_conversation_limit' if ids.size >= count
          ids << subject.conversation_id
        end
        reservation = FollowupBudgetReservation.create!(followup_budget_day: day, subject: subject, attempt_number: subject.attempt_count + 1, reserved_usd: amount)
        day.update!(reserved_usd: day.reserved_usd + amount, conversation_ids: ids, conversation_count: ids.size)
      end
      @pipeline_authorization = { subject_id: subject.id, catalog_id: catalog.id, day_id: day.id, generation: subject.generation,
        revision: subject.revision, fence_token: subject.fence_token + 1, reservation_id: reservation.id }
      reservation
    rescue Followups::CircuitBreaker::Open => error
      raise Exceeded, error.message
    end

    def live_authorized?
      return false if @offline || !@pipeline_authorization || !self.class.installation_authorized?
      shared = current_settings
      Followups::CircuitBreaker.new(settings: shared).check!
      row = PipelineClassificationResult.find_by(id: @pipeline_authorization[:subject_id])
      return false unless row && row.status == 'evaluating' && row.fence_token == @pipeline_authorization[:fence_token] && row.lease_expires_at&.future?
      catalog = row.pipeline_classification_catalog
      return false unless catalog && row.pipeline && Lifecycle.active_catalog(row.pipeline)&.id == catalog.id
      state = PipelineClassificationState.find_by(pipeline_id: row.pipeline_id, conversation_id: row.conversation_id)
      return false unless state && state.generation == row.generation && state.revision == row.revision
      day = FollowupBudgetDay.find_by(id: @pipeline_authorization[:day_id])
      return false unless day && day.timezone == shared['budget_timezone'] && day.budget_date == Time.current.in_time_zone(day.timezone).to_date
      daily = shared['daily_usd']
      count = shared['daily_conversations']
      daily.is_a?(Numeric) && daily.finite? && daily.positive? && count.is_a?(Integer) && count.positive? && day.spent_usd + day.reserved_usd <= BigDecimal(daily.to_s) && day.conversation_count <= count
    rescue Followups::CircuitBreaker::Open, ArgumentError
      false
    end
  end
end
