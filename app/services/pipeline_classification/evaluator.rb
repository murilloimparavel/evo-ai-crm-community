module PipelineClassification
  class Evaluator
    LEASE_SECONDS = 30
    PENDING_STATUSES = %w[reserved retryable_error evaluating].freeze

    # Orphan retirement touches only the historical result. Budget reservations
    # remain in the installation ledger, including unknown in-flight charges.
    def self.retire_orphan!(row)
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
      @row, @client, @budget, @clock = result, client, budget || Budget.new, now || -> { Time.current }
      @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    end

    def call
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
        Followups::CircuitBreaker.new.record(result: response.merge(classification: response[:answers]), model: Catalog::MODEL, questions: compiled.fetch('questions'), now: now)
      end
      finalize!(claim, snapshot, response)
    rescue Budget::Exceeded => error
      close_error!(claim, error.message)
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
        SnapshotBuilder.new(result: @row, catalog: @row.pipeline_classification_catalog, conversation: @row.conversation, now: now).call[:snapshot_hash] == @row.snapshot_hash
    rescue ActiveRecord::RecordNotFound
      false
    end

    private

    def now
      @clock.respond_to?(:call) ? @clock.call : @clock
    end

    def locked
      @row.reload
      pipeline, conversation = @row.pipeline, @row.conversation
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

    def claim!
      claim = nil
      locked do
        available = %w[reserved retryable_error].include?(@row.status) || (@row.status == 'evaluating' && @row.lease_expires_at && @row.lease_expires_at <= now)
        next unless available
        next if @row.next_attempt_at && @row.next_attempt_at > now
        reason = invalid_reason
        if reason
          @row.update!(status: 'blocked', reason: reason)
          next
        end
        reservation = @budget.reserve!(subject: @row, catalog: @row.pipeline_classification_catalog, now: now)
        @row.update!(status: 'evaluating', fence_token: @row.fence_token + 1, attempt_count: @row.attempt_count + 1, lease_expires_at: now + LEASE_SECONDS.seconds)
        claim = { fence: @row.fence_token, reservation: reservation }
      end
      claim
    rescue Budget::Exceeded => error
      locked do
        available = %w[reserved retryable_error].include?(@row.status) || (@row.status == 'evaluating' && @row.lease_expires_at && @row.lease_expires_at <= now)
        @row.update!(status: 'blocked', reason: error.message) if available
      end
      nil
    end

    def invalid_reason
      pipeline, conversation, catalog = @row.pipeline, @row.conversation, @row.pipeline_classification_catalog
      return 'missing_target' unless pipeline && conversation && catalog
      return 'catalog_changed' unless Lifecycle.active_catalog(pipeline)&.id == catalog.id && catalog.catalog_hash == @row.catalog_hash
      profile = catalog.snapshot.fetch('classification')
      return 'inbox_not_allowed' unless profile['inbox_ids'].include?(conversation.inbox_id)
      return 'closed_conversation' unless %w[open pending].include?(conversation.status)
      return 'human_assignee' if conversation.assignee_id.present? || conversation.team_id.present?
      return 'contact_blocked' unless conversation.contact && !conversation.contact.reload.blocked?
      binding = conversation.inbox.agent_bot_inbox
      if binding
        return 'inbox_bot_policy_block' unless binding.active? && !binding.has_ignored_labels?(conversation) && !binding.processing_block_reason(conversation)
      end
      items = conversation.pipeline_items.where(pipeline_id: pipeline.id, completed_at: nil)
      return 'missing_pipeline_item' unless items.count == 1
      return 'pipeline_mismatch' unless items.first.pipeline_stage.pipeline_id == pipeline.id
      state = PipelineClassificationState.find_by(pipeline_id: pipeline.id, conversation_id: conversation.id)
      return 'stale_generation' unless state && state.generation == @row.generation && state.revision == @row.revision && state.source_incoming_message_id == @row.source_incoming_message_id
      return 'selected_context_changed' unless state.context_digest == Lifecycle.context_digest(pipeline, conversation)
      incoming = conversation.messages.find_by(id: @row.source_incoming_message_id, message_type: :incoming, private: false)
      return 'missing_source_incoming' unless incoming
      return 'incoming_changed' if conversation.messages.incoming.where(private: false).where('created_at > ?', incoming.created_at).exists?
      human = conversation.messages.outgoing.where(private: false).where('created_at >= ?', incoming.created_at)
      return 'human_intervention' if human.where(sender_type: 'User').exists? || human.where("content_attributes ->> 'whatsapp_echo_message' = 'true'").exists?
      return 'classification_expired' unless @row.expires_at && @row.expires_at > now
      nil
    end

    def finalize!(claim, snapshot, response)
      locked do
        next unless @row.status == 'evaluating' && @row.fence_token == claim[:fence]
        reason = invalid_reason
        fresh = SnapshotBuilder.new(result: @row, catalog: @row.pipeline_classification_catalog, conversation: @row.conversation, now: now).call if reason.nil? && snapshot[:snapshot_hash]
        if reason || @row.lease_expires_at <= now || (snapshot[:snapshot_hash] && fresh[:snapshot_hash] != snapshot[:snapshot_hash])
          @row.update!(status: 'cancelled', reason: reason || 'snapshot_changed', lease_expires_at: nil)
          next
        end
        response = {} unless response.is_a?(Hash)
        fields = { status: 'abstained', reason: 'invalid_provider_schema', lease_expires_at: nil,
          snapshot_hash: snapshot[:snapshot_hash], recommended_stage_id: nil, decision: {},
          expires_at: [@row.expires_at, snapshot[:valid_until]].compact.min }
        fields[:input_tokens] = response[:input_tokens] if response[:usage_known] == true
        audit = latency_metadata
        audit['served_model'] = response[:served_model] if response[:served_model].is_a?(String) && response[:served_model].match?(/\A[a-zA-Z0-9._:\/-]{1,160}\z/)
        audit['cost_usd'] = response[:cost_usd] if response[:cost_known] == true && response[:cost_usd].is_a?(Numeric) && response[:cost_usd].finite? && response[:cost_usd] >= 0
        fields[:decision].merge!(audit)
        if response[:ok] == true && response[:model] == @row.model
          answer = response.dig(:answers, 'stage_candidate')
          compiled = Catalog.from_revision(@row.pipeline_classification_catalog).compiled
          if answer.is_a?(Hash) && answer['type'] == 'choice' && compiled['questions']['stage_candidate']['criteria'].key?(answer['choice']) && Followups::QuestionValidator.probability?(answer['confidence'])
            choice = answer['choice']
            confidence = answer['confidence']
            fields[:decision].merge!('choice' => choice, 'confidence' => confidence, 'financial_proof' => false)
            threshold = @row.pipeline_classification_catalog.snapshot.dig('classification', 'thresholds', 'stage_candidate')
            if choice == 'unclear' || confidence < threshold
              fields[:reason] = 'uncertain_answer'
            elsif choice == 'no_candidate'
              fields.merge!(status: 'classified', reason: 'no_candidate')
            else
              fields.merge!(status: 'classified', reason: 'stage_recommended', recommended_stage_id: compiled.fetch('aliases').fetch(choice))
            end
          end
        else
          fields[:reason] = response[:reason] if response[:reason].is_a?(String) && response[:reason].match?(/\A[a-z0-9_]{1,100}\z/)
          if response[:retryable] == true && @row.attempt_count < 2
            retry_after = response[:retry_after].is_a?(Numeric) ? response[:retry_after].clamp(1, 3600) : 5
            if now + retry_after.seconds < @row.expires_at
              fields.merge!(status: 'retryable_error', next_attempt_at: now + retry_after.seconds)
            end
          end
        end
        @row.update!(fields)
      end
      @row
    end

    def invoke_provider(client, snapshot, compiled)
      started = monotonic_now
      @provider_started = true
      client.call(state: snapshot.fetch(:state), questions: compiled.fetch('questions'), model: @row.model)
    ensure
      finished = monotonic_now if @provider_started
      if started && finished
        elapsed = (finished - started) * 1000.0
        @provider_latency_ms = elapsed if elapsed.finite? && elapsed >= 0
      end
    end

    def monotonic_now
      value = @monotonic_clock.call
      value if value.is_a?(Numeric) && value.finite? && value >= 0
    rescue StandardError
      nil
    end

    def latency_metadata
      @provider_latency_ms ? { 'provider_latency_ms' => @provider_latency_ms } : {}
    end

    def release_unspent!(claim)
      @budget.settle!(claim[:reservation], usage_known: true, input_tokens: 0, cost_known: true, cost_usd: 0)
    end

    def close_error!(claim, reason)
      return unless claim
      locked do
        @row.update!(status: 'abstained', reason: reason, lease_expires_at: nil, decision: @row.decision.merge(latency_metadata)) if @row.status == 'evaluating' && @row.fence_token == claim[:fence]
      end
    end
  end
end
