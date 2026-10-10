# frozen_string_literal: true

class WhatsappTemplatePublication < ApplicationRecord
  belongs_to :definition, class_name: 'WhatsappTemplateDefinition',
                         foreign_key: :whatsapp_template_definition_id, inverse_of: :publications

  STATUSES = %w[not_submitted submitting submission_unknown pending approved rejected paused flagged failed unknown].freeze
  META_STATUSES = {
    'APPROVED' => 'approved', 'REJECTED' => 'rejected', 'PENDING' => 'pending',
    'PENDING_QUALITY_CHECK' => 'pending', 'PAUSED' => 'paused', 'FLAGGED' => 'flagged'
  }.freeze

  validates :waba_id, presence: true
  validates :waba_id, uniqueness: { scope: :whatsapp_template_definition_id }
  validates :status, inclusion: { in: STATUSES }

  def apply_meta_status!(raw_status:, reason: nil, category: nil, quality: nil, meta_data: {})
    return false if raw_status.blank?
    normalized = META_STATUSES[raw_status.to_s.upcase] || 'unknown'

    update!(status: normalized, raw_status: raw_status.to_s, rejected_reason: reason,
            meta_category: category.presence || meta_category, quality: quality.presence || self.quality,
            meta_data: self.meta_data.to_h.merge(meta_data), synced_at: Time.current, operational_error: nil)
    true
  end
end
