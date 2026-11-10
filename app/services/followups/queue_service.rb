module Followups
  class QueueService
    def initialize(execution:, fence_token:, now: Time.current)
      @execution = execution
      @fence = fence_token
      @now = now
    end

    # Keep all authorization, idempotency and message creation checks within the existing conversation transaction.
    # rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def call
      unless @execution.reload.target_available?
        Retention.retire!(@execution, now: @now)
        return
      end
      conversation = @execution.conversation
      message = nil
      conversation.with_lock do
        state = FollowupConversationState.for!(conversation)
        state.lock!
        campaign = @execution.followup_campaign
        campaign.lock!
        @execution.lock!
        next unless @execution.status == 'ready' && @execution.fence_token == @fence

        reason = Eligibility.new(campaign: campaign, conversation: conversation, execution: @execution, now: @now, dispatch: true).reason
        if reason
          @execution.update!(status: 'cancelled', reason: reason, finalized_at: @now)
          state.update!(active_execution_id: nil) if state.active_execution_id == @execution.id
          next
        end
        if campaign.mode == 'shadow'
          @execution.update!(status: 'abstained', reason: 'shadow_no_writer', finalized_at: @now)
          state.update!(active_execution_id: nil) if state.active_execution_id == @execution.id
          next
        end
        if campaign.mode == 'pilot' && !Eligibility.in_cohort?(campaign, conversation.contact_id)
          @execution.update!(status: 'control', reason: 'control_cohort', finalized_at: @now)
          state.update!(active_execution_id: nil) if state.active_execution_id == @execution.id
          next
        end
        template = FollowupTemplate.find_by(id: @execution.template_id)
        allowed = campaign.policy['steps'].any? { |step| step['step_id'] == @execution.step_id && step['template_id'] == template&.id }
        unless allowed && template&.approved?
          @execution.update!(status: 'blocked', reason: 'template_unapproved', finalized_at: @now)
          state.update!(active_execution_id: nil) if state.active_execution_id == @execution.id
          next
        end
        next @execution.message if @execution.message_id

        other = FollowupExecution.where(conversation_id: conversation.id, source_incoming_message_id: @execution.source_incoming_message_id)
                                 .where(status: %w[queued dispatching dispatched delivered read
                                                   delivery_unknown]).where.not(id: @execution.id).exists?
        next if other || (state.active_execution_id && state.active_execution_id != @execution.id)

        attrs = { 'automation_source' => 'followup_jev_v1', 'followup_template_id' => template.id, 'followup_template_version' => template.version }
        authorization = campaign.policy['channel_authorization']
        additional = {}
        if authorization['template_required']
          additional['template_params'] =
            { 'name' => authorization['template_name'], 'language' => authorization['template_language'],
              'namespace' => authorization['template_namespace'],
              'processed_params' => {} }.compact
        end
        # Message is the existing outbox. Its after_create_commit callback is
        # the only initial enqueue, and sees the FK from this same transaction.
        message = Message.create!(conversation: conversation, inbox_id: conversation.inbox_id, sender: conversation.inbox.agent_bot,
                                  message_type: :outgoing, content_type: :text, private: false, content: template.body,
                                  followup_execution_id: @execution.id, content_attributes: attrs, additional_attributes: additional)
        @execution.update!(message_id: message.id, status: 'queued', lease_expires_at: nil,
                           expires_at: [@execution.expires_at, @now + campaign.policy['authorization_ttl_seconds'].seconds].min)
        state.update!(active_execution_id: @execution.id, cooldown_until: @now + campaign.policy['cooldown_minutes'].minutes)
        FollowupExecution.where(conversation_id: conversation.id,
                                source_incoming_message_id: @execution.source_incoming_message_id,
                                status: FollowupExecution::PENDING).where.not(id: @execution.id)
                         # Keep this lifecycle-only SQL update atomic; callbacks must not reopen cancelled or fenced work.
                         # rubocop:disable Rails/SkipsModelValidations
                         .update_all(status: 'superseded', reason: 'cycle_touch_selected', finalized_at: @now, updated_at: @now)
        # rubocop:enable Rails/SkipsModelValidations
      end
      message
    end
    # rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end
