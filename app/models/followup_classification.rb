class FollowupClassification < ApplicationRecord
  belongs_to :followup_campaign
  belongs_to :conversation, optional: true
  validates :status, inclusion: { in: %w[reserved evaluating retryable_error classified abstained blocked cancelled] }
  validates :generation, :revision, :policy_version, :model, :question_version, presence: true

  def target_available?
    conversation_id.present? && source_incoming_message_id.present? && followup_campaign&.pipeline_stage_id.present? &&
      followup_campaign&.inbox_id.present? && Conversation.exists?(id: conversation_id)
  end
end
