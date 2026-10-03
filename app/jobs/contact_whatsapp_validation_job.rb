# frozen_string_literal: true

class ContactWhatsappValidationJob < ApplicationJob
  queue_as :low

  def perform(contact)
    return if contact.blank? || contact.phone_number.blank?

    # Find the primary WhatsApp inbox with evolution provider
    inbox = Inbox.joins('INNER JOIN channel_whatsapp ON inboxes.channel_id = channel_whatsapp.id')
                 .where(channel_type: 'Channel::Whatsapp')
                 .where("channel_whatsapp.provider = 'evolution'")
                 .first

    return unless inbox

    provider = inbox.channel.provider_service
    return unless provider.respond_to?(:check_whatsapp_number)

    result = provider.check_whatsapp_number(contact.phone_number)
    return unless result.is_a?(Hash)

    contact.custom_attributes ||= {}
    contact.custom_attributes['whatsapp_exists'] = result[:exists]
    contact.custom_attributes['whatsapp_checked_at'] = Time.current.iso8601
    contact.custom_attributes['whatsapp_jid'] = result[:jid] if result[:jid].present?

    # Save columns without re-triggering recursive callbacks
    contact.update_column(:custom_attributes, contact.custom_attributes)
  rescue StandardError => e
    Rails.logger.warn "ContactWhatsappValidationJob failed for contact #{contact&.id}: #{e.message}"
  end
end
