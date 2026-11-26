# frozen_string_literal: true

class Instagram::MessageEditService
  def initialize(messaging:, channel:)
    @messaging = messaging
    @channel = channel
  end

  def perform
    edit = @messaging[:message_edit]
    return if edit.blank?

    message_id = message_id_for(edit)
    edited_text = edited_text_for(edit)
    return if message_id.blank? || edited_text.blank?

    original = Message.joins(:inbox).find_by(source_id: message_id.to_s, inboxes: { channel: @channel })
    update_original(original, edited_text)
  end

  private

  def message_id_for(edit)
    edit[:mid] || edit[:message_id] || edit[:id] || @messaging.dig(:message, :mid)
  end

  def edited_text_for(edit)
    text = edit[:text] || edit.dig(:message, :text) || @messaging.dig(:message, :text)
    text = text[:body] || text['body'] if text.is_a?(Hash)
    text
  end

  def update_original(original, edited_text)
    return unless original&.incoming?
    return if original.content == edited_text && original.content_attributes&.dig('is_edited')

    original.update!(content: edited_text, content_attributes: (original.content_attributes || {}).merge(
      'is_edited' => true,
      'previous_content' => original.content
    ))
  end
end
