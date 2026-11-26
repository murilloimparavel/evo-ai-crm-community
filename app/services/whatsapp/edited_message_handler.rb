# frozen_string_literal: true

class Whatsapp::EditedMessageHandler
  include ::Whatsapp::IncomingMessageServiceHelpers

  def initialize(inbox:, payload:)
    @inbox = inbox
    @payload = payload
  end

  def perform
    original = @inbox.messages.find_by(source_id: original_message_id.to_s)
    update_original(original, edited_content)
  end

  private

  def original_message_id
    payload_value(@payload, :edited_message, :original_message_id) ||
      payload_value(@payload, :edit, :original_message_id) ||
      payload_value(@payload, :context, :id)
  end

  def edited_content
    content = payload_value(@payload, :edited_message, :text, :body) ||
              payload_value(@payload, :edited_message, :body) ||
              payload_value(@payload, :edit, :text, :body) ||
              payload_value(@payload, :text, :body)
    content = payload_value(@payload, :edited_message, :text) if content.is_a?(Hash)
    content
  end

  def update_original(original, content)
    return false unless original&.incoming? && content.present?
    return true if original.content == content && original.content_attributes&.dig('is_edited')

    original.update!(content: content, content_attributes: (original.content_attributes || {}).merge(
      'is_edited' => true,
      'previous_content' => original.content
    ))
  end
end
