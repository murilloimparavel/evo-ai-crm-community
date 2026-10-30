require 'bigdecimal'

module Followups
  class Budget
    class Exceeded < StandardError; end
    PRICE_PER_TOKEN = BigDecimal('0.042') / 1_000_000

    def initialize(offline: false, settings: nil)
      @offline = offline
      @live_authorized = false
      @settings_override = settings&.deep_stringify_keys
    end

    # Only a successful, fully gated reservation can grant the HTTP adapter its
    # installation authorization. The adapter still requires its own ENV/key.
    # Keep the authorization checklist and atomic reservation/settlement ordering intact at the provider boundary.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def live_authorized?
      return false unless @live_authorized == true && !@offline && @authorization

      settings = current_settings
      CircuitBreaker.new(settings: settings).check!
      campaign = FollowupCampaign.find_by(id: @authorization[:campaign_id])
      unless campaign&.running? && campaign.policy_version == @authorization[:policy_version] &&
             campaign.inbox_id == @authorization[:inbox_id] && campaign.pipeline_stage_id == @authorization[:stage_id]
        return false
      end

      limits = campaign.policy.fetch('limits')
      approvals = campaign.policy.fetch('approvals')
      unless settings['online_enabled'] == true && limits['billing_ceiling_verified'] == true &&
             approvals['privacy_reviewed'] == true && approvals['language_validated'] == true &&
             approvals['templates_reviewed'] == true && approvals['retention_days'].is_a?(Integer) && approvals['retention_days'].positive?
        return false
      end

      day = FollowupBudgetDay.find_by(id: @authorization[:day_id])
      return false unless day && day.timezone == settings['budget_timezone'] && day.budget_date == Time.current.in_time_zone(day.timezone).to_date
      unless settings['daily_usd'].is_a?(Numeric) && settings['daily_usd'].finite? && settings['daily_usd'].positive? &&
             settings['daily_conversations'].is_a?(Integer) && settings['daily_conversations'].positive?
        return false
      end

      day.spent_usd + day.reserved_usd <= [BigDecimal(settings['daily_usd'].to_s),
                                           BigDecimal(limits.fetch('daily_usd').to_s)].min &&
        day.conversation_count <= [settings['daily_conversations'],
                                   limits.fetch('daily_conversations')].min
    rescue CircuitBreaker::Open, KeyError, TypeError, ArgumentError
      false
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    # Keep the authorization checklist and atomic reservation/settlement ordering intact at the provider boundary.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def reserve!(subject:, campaign:, now: Time.current)
      @live_authorized = false
      settings = current_settings
      CircuitBreaker.new(settings: settings).check!(now: now)
      limits = campaign.policy.fetch('limits')
      raise Exceeded, 'online_not_authorized' unless @offline || (settings['online_enabled'] == true && limits['billing_ceiling_verified'] == true)

      approvals = campaign.policy['approvals'] || {}
      unless @offline || (approvals['privacy_reviewed'] == true && approvals['language_validated'] == true &&
        approvals['templates_reviewed'] == true && approvals['retention_days'].is_a?(Integer) && approvals['retention_days'].positive?)
        raise Exceeded, 'online_approvals_required'
      end

      zone = settings['budget_timezone']
      raise Exceeded, 'budget_timezone_required' unless TZInfo::Timezone.all_identifiers.include?(zone)

      daily_usd = settings['daily_usd']
      daily_conversations = settings['daily_conversations']
      unless daily_usd.is_a?(Numeric) && daily_usd.positive? && daily_conversations.is_a?(Integer) && daily_conversations.positive?
        raise Exceeded,
              'installation_budget_required'
      end

      amount = PRICE_PER_TOKEN * limits.fetch('max_billable_tokens_per_attempt')
      day = FollowupBudgetDay.create_or_find_by!(scope_key: 'installation', budget_date: now.in_time_zone(zone).to_date) { |row| row.timezone = zone }
      reservation = nil
      day.with_lock do
        raise Exceeded, 'budget_timezone_changed' unless day.timezone == zone

        attempt_number = subject.attempt_count + 1
        raise Exceeded, 'attempt_limit' if attempt_number > limits.fetch('max_attempts')

        known = FollowupBudgetReservation.find_by(subject: subject, attempt_number: attempt_number)
        if known
          reservation = known
          next
        end
        usd_limit = [BigDecimal(daily_usd.to_s), BigDecimal(limits.fetch('daily_usd').to_s)].min
        raise Exceeded, 'daily_cost_limit' if day.spent_usd + day.reserved_usd + amount > usd_limit

        ids = day.conversation_ids.dup
        unless ids.include?(subject.conversation_id)
          limit = [daily_conversations, limits.fetch('daily_conversations')].min
          raise Exceeded, 'daily_conversation_limit' if ids.length >= limit

          ids << subject.conversation_id
        end
        reservation = FollowupBudgetReservation.create!(followup_budget_day: day, subject: subject, attempt_number: attempt_number,
                                                        reserved_usd: amount)
        day.update!(reserved_usd: day.reserved_usd + amount, conversation_ids: ids, conversation_count: ids.length)
      end
      @live_authorized = !@offline
      @authorization = { campaign_id: campaign.id, policy_version: campaign.policy_version, inbox_id: campaign.inbox_id,
                         stage_id: campaign.pipeline_stage_id, day_id: day.id }
      reservation
    rescue CircuitBreaker::Open => e
      raise Exceeded, e.message
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    # Keep the authorization checklist and atomic reservation/settlement ordering intact at the provider boundary.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def settle!(reservation, result)
      tokens = result[:input_tokens]
      return unless result[:usage_known] == true && tokens.is_a?(Integer) && tokens >= 0

      if result.key?(:cost_known)
        cost = result[:cost_usd]
        return unless result[:cost_known] == true && cost.is_a?(Numeric) && cost.finite? && cost >= 0
      end

      day = reservation.followup_budget_day
      day.with_lock do
        reservation.reload
        next unless reservation.status == 'reserved'

        amount = result.key?(:cost_known) ? BigDecimal(result[:cost_usd].to_s) : tokens * PRICE_PER_TOKEN
        day.update!(reserved_usd: day.reserved_usd - reservation.reserved_usd, spent_usd: day.spent_usd + amount)
        reservation.update!(status: 'settled', input_tokens: tokens, actual_usd: amount)
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    private

    def current_settings
      persisted = InstallationConfig.find_by(name: 'FOLLOWUP_SETTINGS')&.value
      return @settings_override || {} if persisted.nil?
      return {} unless persisted.is_a?(Hash)

      (@settings_override || {}).merge(persisted.deep_stringify_keys)
    end
  end
end
