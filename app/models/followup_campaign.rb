class FollowupCampaign < ApplicationRecord
  belongs_to :pipeline_stage, optional: true
  belongs_to :inbox, optional: true
  has_many :followup_executions, dependent: :restrict_with_exception
  has_many :followup_classifications, dependent: :restrict_with_exception
  has_many :followup_anchor_evidences, dependent: :restrict_with_exception

  validates :campaign_key, presence: true, uniqueness: true
  validates :policy_version, presence: true
  validates :engine, inclusion: { in: %w[jev_v1] }
  validates :mode, inclusion: { in: %w[off shadow pilot active] }
  validate :validate_policy
  validate :validate_activation
  validate :version_policy_changes
  after_update_commit :invalidate_affected_work

  scope :running, -> { where(enabled: true, mode: %w[shadow pilot active]) }

  # Retain the full campaign activation checklist, including overlap and validity checks.
  # rubocop:disable Metrics/CyclomaticComplexity
  def running?(now = Time.current)
    enabled? && mode != 'off' && pipeline_stage_id.present? && inbox_id.present? && active_from.present? &&
      active_from <= now && (expires_at.nil? || expires_at > now)
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def policy_object
    Followups::Policy.new(policy)
  end

  def pipeline_catalog?
    policy.is_a?(Hash) && policy['classification_source'] == { 'type' => 'pipeline_catalog' }
  end

  def classifier_config
    return policy.is_a?(Hash) && policy['classifier'].is_a?(Hash) ? policy['classifier'] : {} unless pipeline_catalog?

    { 'model' => Ai::JevClient::OPENROUTER_MODEL, 'question_version' => PipelineClassification::Catalog::COMPILER_VERSION, 'questions' => {} }
  end

  private

  def invalidate_affected_work
    return unless previous_changes.keys.intersect?(%w[enabled mode policy policy_version active_from expires_at pipeline_stage_id inbox_id])

    Followups::Lifecycle.campaign_updated(self)
  end

  def version_policy_changes
    return unless persisted? && will_save_change_to_policy?

    errors.add(:policy_version, 'must change with policy data') unless will_save_change_to_policy_version?
    previous_salt = policy_in_database.to_h.dig('cohort', 'salt')
    return unless previous_salt.present? && previous_salt != policy.to_h.dig('cohort', 'salt')

    errors.add(:policy, 'cohort salt is immutable for stable contact allocation')
  end

  def validate_policy
    # An emergency OFF must remain possible even for corrupted configuration.
    return unless enabled? && mode != 'off'

    policy_object.errors.each { |error| errors.add(:policy, error) }
  end

  # Retain the full campaign activation checklist, including overlap and validity checks.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def validate_activation
    return unless enabled? && mode != 'off'

    errors.add(:active_from, 'is required for activation') unless active_from
    errors.add(:expires_at, 'must follow activation') if expires_at && active_from && expires_at <= active_from
    errors.add(:base, 'legacy inactivity overlaps this target') if Followups::Eligibility.legacy_overlap?(self)
    overlapping = self.class.where(enabled: true, pipeline_stage_id: pipeline_stage_id, inbox_id: inbox_id).where.not(id: id)
    errors.add(:base, 'another campaign already targets this inbox and stage') if overlapping.exists?
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
end
