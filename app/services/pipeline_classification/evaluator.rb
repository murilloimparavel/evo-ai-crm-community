module PipelineClassification
  class Evaluator
    include EvaluationGuard
    include EvaluationResult
    LEASE_SECONDS = 30
    PENDING_STATUSES = %w[reserved retryable_error evaluating].freeze

    # Orphan retirement touches only the historical result. Budget reservations
    # remain in the installation ledger, including unknown in-flight charges.
    # Keep claim/fence validation and settlement handling in their existing transaction boundaries.
    def self.retire_orphan!(row) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      retired = false
      row.with_lock do
        next unless PENDING_STATUSES.include?(row.status)

        available = row.pipeline_id && Pipeline.exists?(id: row.pipeline_id) &&
                    row.conversation_id && Conversation.exists?(id: row.conversation_id) &&
                    row.pipeline_classification_catalog_id && PipelineClassificationCatalog.exists?(id: row.pipeline_classification_catalog_id)
        next if available

        row.update!(status: 'cancelled', reason: 'target_deleted', lease_expires_at: nil,
                    next_attempt_at: nil, fence_token: row.fence_token + 1)
        retired = true
      end
      retired
    rescue ActiveRecord::RecordNotFound
      false
    end

    def self.retire_orphans!
      PipelineClassificationResult.where(status: PENDING_STATUSES)
                                  .left_joins(:pipeline, :conversation, :pipeline_classification_catalog)
                                  .where('pipelines.id IS NULL OR conversations.id IS NULL OR pipeline_classification_catalogs.id IS NULL')
                                  .limit(100).find_each { |row| retire_orphan!(row) }
    end

    def initialize(result:, client: nil, budget: nil, now: nil, monotonic_clock: nil)
      @row = result
      @client = client
      @budget = budget || Budget.new
      @clock = now || -> { Time.current }
      @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    end

    # Keep claim/fence validation and settlement handling in their existing transaction boundaries.
    def call # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      @provider_started = false
      @provider_latency_ms = nil
      return if self.class.retire_orphan!(@row)

      @row.reload
      claim = claim!
      return unless claim

      snapshot = SnapshotBuilder.new(result: @row, catalog: @row.pipeline_classification_catalog, conversation: @row.conversation, now: now).call
      unless snapshot[:state].is_a?(Hash) && snapshot[:valid_until] > now
        release_unspent!(claim)
        return finalize!(claim, snapshot, { ok: false, reason: snapshot[:reason] || 'invalid_snapshot', usage_known: true, input_tokens: 0 })
      end
      unless @client || @budget.live_authorized?
        release_unspent!(claim)
        return finalize!(claim, snapshot, { ok: false, reason: 'online_authorization_changed' })
      end
      client = @client || Ai::DecisionClient.for_pipeline(model: @row.model, live_authorized: @budget.live_authorized?)
      compiled = Catalog.from_revision(@row.pipeline_classification_catalog).compiled
      response = invoke_provider(client, snapshot, compiled)
      @budget.settle!(claim[:reservation], response) if response.is_a?(Hash)
      # Failure codes share the installation breaker. No body or customer text is
      # retained; a credential error requires the same human reset as follow-up.
      if response.is_a?(Hash)
        Followups::CircuitBreaker.new.record(result: response.merge(classification: response[:answers]), model: Catalog::MODEL,
                                             questions: compiled.fetch('questions'), now: now)
      end
      finalize!(claim, snapshot, response)
    rescue Budget::Exceeded => e
      close_error!(claim, e.message)
    rescue StandardError
      if claim && @provider_started
        begin
          Followups::CircuitBreaker.new.record(result: { reason: 'classification_transport_error' }, now: now)
        rescue StandardError
          nil
        end
      end
      release_unspent!(claim) if claim && !@provider_started
      close_error!(claim, 'classification_failed')
    end

    # Consumers must revalidate the accepted generation and source digest, not
    # rely on the row's historical status alone.
    def current?
      @row.reload
      @row.status == 'classified' && invalid_reason.nil? && @row.expires_at > now &&
        SnapshotBuilder.new(result: @row, catalog: @row.pipeline_classification_catalog, conversation: @row.conversation,
                            now: now).call[:snapshot_hash] == @row.snapshot_hash
    rescue ActiveRecord::RecordNotFound
      false
    end

    private

    def now
      @clock.respond_to?(:call) ? @clock.call : @clock
    end

    def locked
      @row.reload
      pipeline = @row.pipeline
      conversation = @row.conversation
      unless pipeline && conversation && @row.pipeline_classification_catalog
        self.class.retire_orphan!(@row)
        return
      end
      pipeline.with_lock do
        conversation.with_lock do
          state = PipelineClassificationState.find_by(pipeline_id: pipeline.id, conversation_id: conversation.id)
          next unless state

          state.lock!
          @row.lock!
          yield state
        end
      end
    rescue ActiveRecord::RecordNotFound
      self.class.retire_orphan!(@row)
      nil
    end

    def claim_available?
      %w[reserved retryable_error].include?(@row.status) ||
        (@row.status == 'evaluating' && @row.lease_expires_at && @row.lease_expires_at <= now)
    end

    # Keep claim/fence validation and settlement handling in their existing transaction boundaries.
    def claim! # rubocop:disable Metrics/MethodLength
      claim = nil
      locked do
        available = claim_available?
        next unless available
        next if @row.next_attempt_at && @row.next_attempt_at > now

        reason = invalid_reason
        if reason
          @row.update!(status: 'blocked', reason: reason)
          next
        end
        reservation = @budget.reserve!(subject: @row, catalog: @row.pipeline_classification_catalog, now: now)
        @row.update!(status: 'evaluating', fence_token: @row.fence_token + 1, attempt_count: @row.attempt_count + 1,
                     lease_expires_at: now + LEASE_SECONDS.seconds)
        claim = { fence: @row.fence_token, reservation: reservation }
      end
      claim
    rescue Budget::Exceeded => e
      locked do
        available = claim_available?
        @row.update!(status: 'blocked', reason: e.message) if available
      end
      nil
    end

    # Keep claim/fence validation and settlement handling in their existing transaction boundaries.
    def finalize!(claim, snapshot, response) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      locked do
        next unless @row.status == 'evaluating' && @row.fence_token == claim[:fence]

        reason = invalid_reason
        if reason.nil? && snapshot[:snapshot_hash]
          fresh = SnapshotBuilder.new(result: @row, catalog: @row.pipeline_classification_catalog, conversation: @row.conversation,
                                      now: now).call
        end
        if reason || @row.lease_expires_at <= now || (snapshot[:snapshot_hash] && fresh[:snapshot_hash] != snapshot[:snapshot_hash])
          @row.update!(status: 'cancelled', reason: reason || 'snapshot_changed', lease_expires_at: nil)
          next
        end
        fields = normalized_fields(snapshot, response)
        @row.update!(fields)
      end
      @row
    end

    def release_unspent!(claim)
      @budget.settle!(claim[:reservation], usage_known: true, input_tokens: 0, cost_known: true, cost_usd: 0)
    end

    def close_error!(claim, reason)
      return unless claim

      locked do
        if @row.status == 'evaluating' && @row.fence_token == claim[:fence]
          @row.update!(status: 'abstained', reason: reason, lease_expires_at: nil,
                       decision: @row.decision.merge(latency_metadata))
        end
      end
    end
  end
end
