class FollowupExecution < ApplicationRecord
  PENDING = %w[reserved evaluating retryable_error ready queued].freeze
  STATUSES = (PENDING + %w[dispatching dispatched delivered read delivery_unknown permanent_failure cancelled superseded abstained blocked
                           control]).freeze
  belongs_to :followup_campaign
  belongs_to :conversation, optional: true
  belongs_to :pipeline_item, optional: true
  belongs_to :followup_anchor_evidence
  belongs_to :message, optional: true
  belongs_to :pipeline_classification_result, optional: true
  validates :status, inclusion: { in: STATUSES }
  validates :step_id, :policy_version, :due_at, :expires_at, presence: true
  scope :pending, -> { where(status: PENDING) }

  # Retain all linked target identity checks before treating a commercial execution as usable.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def target_available?
    conversation_id.present? && pipeline_item_id.present? && source_incoming_message_id.present? && quote_anchor_message_id.present? &&
      followup_campaign&.pipeline_stage_id.present? && followup_campaign&.inbox_id.present? &&
      followup_anchor_evidence&.anchor_message_id.present? && followup_anchor_evidence&.source_incoming_message_id.present? &&
      Conversation.exists?(id: conversation_id) && PipelineItem.exists?(id: pipeline_item_id) &&
      (%w[queued dispatching].exclude?(status) || (message_id.present? && Message.exists?(id: message_id)))
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
end
