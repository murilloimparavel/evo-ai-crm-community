require 'digest'

class FollowupTemplate < ApplicationRecord
  belongs_to :approved_by, class_name: 'User', optional: true
  validates :template_key, :version, :body, presence: true
  validates :version, uniqueness: { scope: :template_key }
  validates :body, length: { maximum: 800 }
  before_validation :invalidate_changed_approval

  def approved?
    active? && approved_at.present? && approved_by_id.present? && body_digest == Digest::SHA256.hexdigest(body.to_s)
  end

  private

  def invalidate_changed_approval
    return unless persisted? && will_save_change_to_body?

    self.approved_at = nil
    self.approved_by_id = nil
    self.active = false
    self.body_digest = nil
  end
end
