module Followups
  class Planner
    def initialize(evidence:, now: Time.current)
      @evidence = evidence
      @now = now
    end

    # Keep commercial evidence, unique execution creation and scheduling checks inside the existing transaction.
    # rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def call
      campaign = @evidence.followup_campaign
      conversation = @evidence.conversation
      return [] if Eligibility.new(campaign: campaign, conversation: conversation, now: @now).reason
      return [] if EvidenceApproval.invalid_reason(@evidence, now: @now)

      result = []
      conversation.with_lock do
        state = FollowupConversationState.for!(conversation)
        state.lock!
        policy = campaign.policy_object
        base = [@evidence.source_incoming_message.created_at, @evidence.anchor_message.created_at].max
        steps = policy['steps'].sort_by { |step| step['delay_minutes'] }
        due_steps = steps.select { |step| base + step['delay_minutes'].minutes <= @now }
        selected = due_steps.last || steps.first
        steps.each do |step|
          due = base + step['delay_minutes'].minutes
          next if step != selected && due > @now

          expiry = due + policy['max_lateness_minutes'].minutes
          status = step == selected && expiry > @now ? 'reserved' : 'superseded'
          execution = FollowupExecution.create_or_find_by!(followup_campaign: campaign, conversation: conversation,
                                                           source_incoming_message_id: @evidence.source_incoming_message_id,
                                                           step_id: step['step_id']) do |row|
            row.assign_attributes(pipeline_item: @evidence.pipeline_item, followup_anchor_evidence: @evidence,
                                  quote_anchor_message_id: @evidence.anchor_message_id,
                                  policy_version: campaign.policy_version, status: status,
                                  due_at: policy.next_window(due) || due, expires_at: expiry,
                                  authorized_revision: state.revision, template_id: step['template_id'])
          end
          execution.lock!
          changed_context = execution.followup_anchor_evidence_id != @evidence.id ||
                            execution.policy_version != campaign.policy_version || execution.authorized_revision != state.revision
          if changed_context && execution.message_id.nil? && %w[cancelled blocked abstained].include?(execution.status) && status == 'reserved'
            # Only an explicit operator approval reaches this planner. Preserve
            # identity and all prior billing reservations; never replay an outbox.
            execution.update!(pipeline_item: @evidence.pipeline_item, followup_anchor_evidence: @evidence,
                              quote_anchor_message_id: @evidence.anchor_message_id, policy_version: campaign.policy_version,
                              authorized_revision: state.revision, status: status, due_at: policy.next_window(due) || due,
                              expires_at: expiry, template_id: step['template_id'], snapshot_hash: nil, decision: nil,
                              reason: nil, lease_expires_at: nil, next_attempt_at: nil, finalized_at: nil,
                              fence_token: execution.fence_token + 1)
          end
          result << execution
        end
      end
      result
    end
    # rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end
