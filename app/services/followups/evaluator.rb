module Followups
  # Owns persistence and billing; the classifier is a side-effect-free adapter.
  class Evaluator
    LEASE_SECONDS = 30

    def initialize(subject:, classifier: nil, snapshot_builder: nil, budget: nil, now: nil)
      @subject = subject
      @classifier = classifier
      @snapshot_builder = snapshot_builder
      @budget = budget || Budget.new
      @clock = now || -> { Time.current }
    end

    def call
      @provider_started = false
      @provider_result_recorded = false
      @classifier ||= CatalogClassifier.new(campaign: campaign, subject: @subject) if campaign.pipeline_catalog?
      unless @subject.reload.target_available?
        Retention.retire!(@subject, now: now)
        return
      end
      claim = reserve
      return unless claim

      builder = @snapshot_builder || SnapshotBuilder.new(campaign: campaign, conversation: @subject.conversation, execution: execution? ? @subject : nil, classification: execution? ? nil : @subject, now: now)
      snapshot = builder.call
      unless snapshot.is_a?(Hash) && snapshot[:snapshot_hash].is_a?(String) && snapshot[:valid_until].respond_to?(:>) && snapshot[:valid_until] > now
        @budget.settle!(claim[:reservation], usage_known: true, input_tokens: 0)
        reason = snapshot.is_a?(Hash) && snapshot[:reason].is_a?(String) ? snapshot[:reason] : 'invalid_snapshot'
        return finish_error(claim, reason, retryable: false)
      end

      unless @classifier || @budget.live_authorized?
        @budget.settle!(claim[:reservation], usage_known: true, input_tokens: 0)
        return finish_error(claim, 'online_authorization_changed', retryable: false)
      end
      classifier = @classifier || Classifier.new(client: Ai::JevClient.new(live_authorized: @budget.live_authorized?))
      @provider_started = !campaign.pipeline_catalog?
      result = classifier.classify(snapshot: snapshot, policy: campaign.policy)
      @budget.settle!(claim[:reservation], result) if result.is_a?(Hash)
      CircuitBreaker.new.record(result: result, campaign: campaign, now: now) unless campaign.pipeline_catalog?
      @provider_result_recorded = true
      finish(claim, snapshot, normalize(result))
    rescue Budget::Exceeded => e
      finish_error(claim, e.message, retryable: false)
    rescue StandardError
      # Do not persist provider bodies, transcript fragments or arbitrary errors.
      @budget.settle!(claim[:reservation], usage_known: true, input_tokens: 0) if claim && !@provider_started
      record_unexpected_provider_failure if claim && @provider_started && !@provider_result_recorded
      finish_error(claim, 'evaluation_failed', retryable: false)
    end

    private

    def record_unexpected_provider_failure
      CircuitBreaker.new.record(result: { reason: 'classification_transport_error' }, campaign: campaign, now: now)
    rescue StandardError
      # A failed breaker persistence must still leave the execution closed and
      # its unknown-usage reservation intact; never retry the provider here.
      nil
    end

    def execution?
      @subject.is_a?(FollowupExecution)
    end

    def campaign
      @subject.followup_campaign
    end

    def now
      @clock.respond_to?(:call) ? @clock.call : @clock
    end

    def reserve
      claim = nil
      @subject.conversation.with_lock do
        state = FollowupConversationState.for!(@subject.conversation)
        state.lock!
        campaign.lock!
        @subject.lock!
        eligible_status = %w[reserved retryable_error].include?(@subject.status) || (@subject.status == 'evaluating' && @subject.lease_expires_at && @subject.lease_expires_at <= now)
        next unless eligible_status
        next if @subject.next_attempt_at && @subject.next_attempt_at > now
        next if execution? && @subject.due_at > now

        reason = Eligibility.new(campaign: campaign, conversation: @subject.conversation, execution: execution? ? @subject : nil, now: now).reason
        if !execution? && (state.classification_generation != @subject.generation || state.revision != @subject.revision || state.latest_incoming_message_id != @subject.source_incoming_message_id)
          reason = 'stale_generation'
        end
        if @subject.policy_version != campaign.policy_version || (!execution? && (@subject.model != campaign.classifier_config['model'] || @subject.question_version != campaign.classifier_config['question_version']))
          reason = 'policy_changed'
        end
        reason = 'classification_expired' if @subject.expires_at && @subject.expires_at <= now
        if reason
          @subject.update!(status: 'blocked', reason: reason)
          next
        end
        # A conversation-level slot protects different rules/campaigns too.
        if execution? && state.active_execution_id.present? && state.active_execution_id != @subject.id
          @subject.update!(status: 'blocked', reason: 'conversation_claimed')
          next
        end
        reservation = @budget.reserve!(subject: @subject, campaign: campaign, now: now)
        fence = @subject.fence_token + 1
        @subject.update!(status: 'evaluating', fence_token: fence, lease_expires_at: now + LEASE_SECONDS.seconds, attempt_count: @subject.attempt_count + 1)
        state.update!(active_execution_id: @subject.id) if execution?
        claim = { fence: fence, revision: state.revision, generation: state.classification_generation, policy_version: campaign.policy_version, reservation: reservation }
      end
      claim
    rescue Budget::Exceeded => e
      @subject.update!(status: 'blocked', reason: e.message)
      nil
    end

    def normalize(result)
      return { action: 'abstain', reason: 'invalid_classifier_result' } unless result.is_a?(Hash)
      config = campaign.classifier_config
      valid = %w[send block abstain].include?(result[:action]) && result[:reason].is_a?(String) && result[:reason].match?(/\A[a-z0-9_]{1,100}\z/) && result[:model] == config['model'] && result[:question_version] == config['question_version']
      valid &&= [true, false].include?(result[:usage_known]) && (result[:usage_known] == false || (result[:input_tokens].is_a?(Integer) && result[:input_tokens] >= 0))
      return { action: 'abstain', reason: 'invalid_classifier_result' } unless valid
      if result[:action] == 'send'
        ids = campaign.policy['steps'].map { |step| step['template_id'] }
        return { action: 'abstain', reason: 'invalid_template_selection' } unless ids.include?(result[:template_id])
      end
      result
    end

    def finish(claim, snapshot, result)
      queue = false
      @subject.conversation.with_lock do
        state = FollowupConversationState.for!(@subject.conversation)
        state.lock!
        campaign.lock!
        @subject.lock!
        next unless @subject.status == 'evaluating' && @subject.fence_token == claim[:fence]
        valid = state.revision == claim[:revision] && state.classification_generation == claim[:generation] && campaign.policy_version == claim[:policy_version] && @subject.lease_expires_at > now && snapshot[:valid_until] > now
        reason = Eligibility.new(campaign: campaign, conversation: @subject.conversation, execution: execution? ? @subject : nil, now: now).reason
        unless valid && reason.nil?
          @subject.update!(status: 'cancelled', reason: reason || 'stale_evaluation')
          release_slot(state)
          next
        end
        @subject.snapshot_hash = snapshot[:snapshot_hash]
        @subject.input_tokens = result[:input_tokens] if result[:usage_known] == true
        @subject.reason = result[:reason]
        @subject.lease_expires_at = nil
        if result[:retryable] == true && @subject.attempt_count < campaign.policy.dig('limits', 'max_attempts')
          delay = result[:retry_after].is_a?(Numeric) && result[:retry_after].finite? ? [result[:retry_after], 1].max : 5
          retry_at = now + delay.seconds
          if retry_at < @subject.expires_at
            @subject.status = 'retryable_error'
            @subject.next_attempt_at = retry_at
            @subject.save!
            release_slot(state)
            next
          end
        end
        if execution?
          @subject.decision = result[:action]
          @subject.model = campaign.classifier_config['model']
          @subject.question_version = campaign.classifier_config['question_version']
          if campaign.pipeline_catalog? && result[:action] == 'send'
            @subject.pipeline_classification_result_id = result[:pipeline_classification_result_id]
            @subject.classification_catalog_hash = result[:classification_catalog_hash]
          end
          @subject.template_id = result[:template_id] if result[:action] == 'send'
          @subject.status = { 'send' => 'ready', 'block' => 'blocked', 'abstain' => 'abstained' }.fetch(result[:action])
          if campaign.mode == 'shadow' && @subject.status == 'ready'
            # Shadow never constructs a writer, even when it would recommend
            # SEND. QueueService also denies shadow as a second safety check.
            @subject.status = 'abstained'
            @subject.reason = 'shadow_no_writer'
          end
          @subject.finalized_at = now unless @subject.status == 'ready'
          queue = @subject.status == 'ready'
        else
          @subject.decision = result.slice(:action, :reason, :template_id, :model, :question_version).stringify_keys
          @subject.decision['proposed_action'] = result[:proposed_action] if %w[send block abstain].include?(result[:proposed_action])
          @subject.decision['classification'] = sanitized_answers(result[:classification]) if result[:classification].is_a?(Hash)
          @subject.status = { 'send' => 'classified', 'block' => 'blocked', 'abstain' => 'abstained' }.fetch(result[:action])
        end
        @subject.save!
        release_slot(state) unless queue
      end
      QueueService.new(execution: @subject, fence_token: claim[:fence], now: now).call if queue
      @subject
    end

    def finish_error(claim, reason, retryable:)
      return unless claim

      changed = @subject.class.where(id: @subject.id, status: 'evaluating', fence_token: claim[:fence]).update_all(status: retryable ? 'retryable_error' : 'abstained', reason: reason, lease_expires_at: nil, updated_at: now)
      return unless changed == 1
      conversation = Conversation.find_by(id: @subject.reload.conversation_id)
      return unless conversation
      conversation.with_lock do
        state = FollowupConversationState.for!(conversation)
        state.lock!
        @subject.lock!
        release_slot(state) if @subject.fence_token == claim[:fence]
      end
      nil
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def release_slot(state)
      state.update!(active_execution_id: nil) if execution? && state.active_execution_id == @subject.id
    end

    def sanitized_answers(answers)
      questions = campaign.classifier_config['questions'] || {}
      answers.each_with_object({}) do |(key, value), clean|
        next unless questions.key?(key.to_s) && value.is_a?(Hash)
        question = questions[key.to_s]
        typed = value.stringify_keys.slice('type', 'choice', 'confidence', 'noul', 'score', 'probabilities')
        clean[key.to_s] = typed.select do |field, item|
          case field
          when 'type' then item == question['type']
          when 'choice' then question['type'] == 'choice' && item.is_a?(String) && question['criteria'].is_a?(Hash) && question['criteria'].key?(item)
          when 'confidence' then %w[choice score].include?(question['type']) && probability?(item)
          when 'noul' then question['type'] == 'noul' && probability?(item)
          when 'score' then question['type'] == 'score' && question['criteria'].is_a?(Array) && item.is_a?(Numeric) && item.finite? && item.between?(0, question['criteria'].length - 1)
          when 'probabilities' then valid_probabilities?(item, question)
          else false
          end
        end
      end
    end

    def probability?(value)
      value.is_a?(Numeric) && value.finite? && value.between?(0, 1)
    end

    def valid_probabilities?(value, question)
      keys = if question['type'] == 'choice' && question['criteria'].is_a?(Hash)
               question['criteria'].keys
             elsif question['type'] == 'score' && question['criteria'].is_a?(Array)
               question['criteria'].each_index.map(&:to_s)
             end
      keys && value.is_a?(Hash) && value.keys.sort == keys.sort && value.values.all? { |number| probability?(number) } && (value.values.sum - 1).abs <= 0.001
    end
  end
end
