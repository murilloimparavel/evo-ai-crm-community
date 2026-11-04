require 'bigdecimal'

module PipelineClassification
  # Installation-scoped budget and provider authorization dedicated to this feature.
  class Budget
    class Exceeded < StandardError; end

    def self.settings
      value = InstallationConfig.find_by(name: 'PIPELINE_CLASSIFICATION_SETTINGS')&.value
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end

    def self.installation_authorized?
      RuntimeSettings.authorized?(settings)
    end

    def self.automatic_moves_authorized?
      settings['automatic_moves_enabled'] == true
    end

    def initialize(offline: false, settings: nil)
      @offline = offline
      @settings_override = settings&.deep_stringify_keys
      @authorization = nil
    end

    def reserve!(subject:, catalog:, now: Time.current) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      @authorization = nil
      limits = current_settings
      CircuitBreaker.new(settings: limits).check!(now: now)
      raise Exceeded, 'online_approvals_required' unless @offline || self.class.installation_authorized?

      ceiling = limits['max_attempt_cost_usd']
      raise Exceeded, 'verified_attempt_ceiling_required' unless ceiling.is_a?(Numeric) && ceiling.finite? && ceiling.positive?

      zone = limits['budget_timezone']
      raise Exceeded, 'budget_timezone_required' unless TZInfo::Timezone.all_identifiers.include?(zone)

      daily = limits['daily_usd']
      count = limits['daily_conversations']
      unless daily.is_a?(Numeric) && daily.finite? && daily.positive? && count.is_a?(Integer) && count.positive?
        raise Exceeded, 'installation_budget_required'
      end
      raise Exceeded, 'attempt_limit' if subject.attempt_count >= 2

      day = PipelineClassificationBudgetDay.create_or_find_by!(scope_key: 'installation', budget_date: now.in_time_zone(zone).to_date) do |row|
        row.timezone = zone
      end
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
        reservation = PipelineClassificationBudgetReservation.create!(pipeline_classification_budget_day: day,
                                                                      pipeline_classification_result: subject,
                                                                      attempt_number: subject.attempt_count + 1,
                                                                      reserved_usd: amount)
        day.update!(reserved_usd: day.reserved_usd + amount, conversation_ids: ids, conversation_count: ids.size)
      end
      @authorization = { subject_id: subject.id, catalog_id: catalog.id, day_id: day.id,
                         fence_token: subject.fence_token + 1, reservation_id: reservation.id }
      reservation
    rescue CircuitBreaker::Open => e
      raise Exceeded, e.message
    end

    def live_authorized? # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      return false if @offline || !@authorization || !self.class.installation_authorized?

      limits = current_settings
      CircuitBreaker.new(settings: limits).check!
      row = PipelineClassificationResult.find_by(id: @authorization[:subject_id])
      return false unless row && row.status == 'evaluating' && row.fence_token == @authorization[:fence_token] && row.lease_expires_at&.future?

      catalog = row.pipeline_classification_catalog
      return false unless catalog && row.pipeline && Lifecycle.active_catalog(row.pipeline)&.id == catalog.id

      state = PipelineClassificationState.find_by(pipeline_id: row.pipeline_id, conversation_id: row.conversation_id)
      return false unless state && state.generation == row.generation && state.revision == row.revision

      day = PipelineClassificationBudgetDay.find_by(id: @authorization[:day_id])
      return false unless day && day.timezone == limits['budget_timezone'] && day.budget_date == Time.current.in_time_zone(day.timezone).to_date

      daily = limits['daily_usd']
      count = limits['daily_conversations']
      daily.is_a?(Numeric) && daily.finite? && daily.positive? && count.is_a?(Integer) && count.positive? &&
        day.spent_usd + day.reserved_usd <= BigDecimal(daily.to_s) && day.conversation_count <= count
    rescue CircuitBreaker::Open, ArgumentError
      false
    end

    # Unknown in-flight usage keeps its full reservation until an operator reconciles it.
    def settle!(reservation, result) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      return unless result.is_a?(Hash) && result[:usage_known] == true && result[:input_tokens].is_a?(Integer) && result[:input_tokens] >= 0
      return unless result[:cost_known] == true && result[:cost_usd].is_a?(Numeric) && result[:cost_usd].finite? && result[:cost_usd] >= 0

      day = reservation.pipeline_classification_budget_day
      day.with_lock do
        reservation.reload
        next unless reservation.status == 'reserved'

        actual = BigDecimal(result[:cost_usd].to_s)
        day.update!(reserved_usd: day.reserved_usd - reservation.reserved_usd, spent_usd: day.spent_usd + actual)
        reservation.update!(status: 'settled', input_tokens: result[:input_tokens], actual_usd: actual)
      end
    end

    private

    def current_settings
      persisted = self.class.settings
      persisted.merge(@settings_override || {})
    end
  end
end
