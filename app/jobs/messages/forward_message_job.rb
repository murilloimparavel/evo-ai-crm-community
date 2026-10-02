class Messages::ForwardMessageJob < ApplicationJob
  queue_as :default

  def perform(source_conversation_id, source_message_id, contact_id, inbox_id, user_id)
    source_conversation = Conversation.find(source_conversation_id)
    source_message = source_conversation.messages.find(source_message_id)
    inbox = Inbox.find(inbox_id)
    contact = Contact.find(contact_id)
    user = User.find(user_id)

    raise 'Forwarding is available only for WhatsApp conversations' unless inbox.channel_type == 'Channel::Whatsapp'
    return if contact.phone_number.blank?
    source_attributes = source_message.content_attributes || {}
    unavailable = source_attributes['deleted'] || source_attributes['revoked_by_contact']
    return if source_message.private? || source_message.activity? || source_message.template? || unavailable

    contact_inbox = inbox.contact_inboxes.find_by(contact_id: contact.id) ||
                    ContactInboxBuilder.new(contact: contact, inbox: inbox).perform
    conversation = ConversationBuilder.new(params: ActionController::Parameters.new, contact_inbox: contact_inbox).perform
    forwarding_key = { forwarded_source_message_id: source_message.id.to_s, forwarding_contact_id: contact.id.to_s }
    return if conversation.messages.where("content_attributes ->> 'forwarded_source_message_id' = ? AND content_attributes ->> 'forwarding_contact_id' = ?", *forwarding_key.values).exists?

    blob_ids = source_message.attachments.filter_map do |attachment|
      attachment.file.blob.signed_id if attachment.file.attached?
    end
    return if source_message.attachments.any? && blob_ids.length != source_message.attachments.length
    params = ActionController::Parameters.new(
      content: source_message.content,
      message_type: 'outgoing',
      private: false,
      attachments: blob_ids,
      content_attributes: forwarding_key
    )
    Messages::MessageBuilder.new(user, conversation, params).perform
  end
end
