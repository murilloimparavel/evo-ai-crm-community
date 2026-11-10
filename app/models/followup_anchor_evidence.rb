class FollowupAnchorEvidence < ApplicationRecord
  belongs_to :followup_campaign
  belongs_to :conversation, optional: true
  belongs_to :pipeline_item, optional: true
  belongs_to :source_incoming_message, class_name: 'Message', optional: true
  belongs_to :anchor_message, class_name: 'Message', optional: true
  belongs_to :verified_by, class_name: 'User', optional: true
  validates :anchor_digest, :verified_at, presence: true
  validates :evidence_method, inclusion: { in: %w[operator_verified] }
end
