module Followups
  class Retention
    def self.retire!(record, now: Time.current)
      record.with_lock do
        record.reload
        next false if record.target_available?

        if record.is_a?(FollowupExecution)
          next false unless (FollowupExecution::PENDING + ['dispatching']).include?(record.status)

          status = record.status == 'dispatching' ? 'delivery_unknown' : 'cancelled'
          record.update!(status: status, reason: 'target_deleted', lease_expires_at: nil, finalized_at: status == 'cancelled' ? now : nil)
        elsif %w[reserved evaluating retryable_error].include?(record.status)
          record.update!(status: 'cancelled', reason: 'target_deleted', lease_expires_at: nil)
        end
        true
      end
    end

    # Keep this closed safety contract and its existing ordering intact during release formatting.
    # rubocop:disable Metrics/MethodLength
    def self.retire_orphans!(now: Time.current)
      FollowupExecution.where(status: FollowupExecution::PENDING + ['dispatching'])
                       .left_joins(:followup_campaign, :followup_anchor_evidence)
                       .where('followup_executions.conversation_id IS NULL OR ' \
                              'followup_executions.pipeline_item_id IS NULL OR ' \
                              'followup_executions.source_incoming_message_id IS NULL OR ' \
                              'followup_executions.quote_anchor_message_id IS NULL OR ' \
                              'followup_campaigns.pipeline_stage_id IS NULL OR ' \
                              'followup_campaigns.inbox_id IS NULL OR ' \
                              'followup_anchor_evidences.anchor_message_id IS NULL OR ' \
                              'followup_anchor_evidences.source_incoming_message_id IS NULL OR ' \
                              '(followup_executions.status IN (?) AND followup_executions.message_id IS NULL)', %w[
                                queued dispatching
                              ])
                       .limit(100).find_each { |row| retire!(row, now: now) }
      FollowupClassification.where(status: %w[reserved evaluating retryable_error])
                            .left_joins(:followup_campaign)
                            .where('followup_classifications.conversation_id IS NULL OR ' \
                                   'followup_classifications.source_incoming_message_id IS NULL OR ' \
                                   'followup_campaigns.pipeline_stage_id IS NULL OR followup_campaigns.inbox_id IS NULL')
                            .limit(100).find_each { |row| retire!(row, now: now) }
    end
    # rubocop:enable Metrics/MethodLength
  end
end
