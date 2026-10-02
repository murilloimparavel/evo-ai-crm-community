class Api::V1::Conversations::MessagesController < Api::V1::Conversations::BaseController
  require_permissions({
    index: 'conversations.read',
    create: 'conversations.update',
    update: 'conversations.update',
    destroy: 'conversations.update',
    retry: 'conversations.update',
    forward: 'conversations.update'
  })

  before_action :ensure_api_inbox, only: :update

  def index
    @messages = message_finder.perform

    success_response(
      data: MessageSerializer.serialize_collection(@messages, include_attachments: true, include_sender: true),
      message: 'Messages retrieved successfully'
    )
  end

  def create
    user = Current.user || @resource
    mb = Messages::MessageBuilder.new(user, @conversation, params)
    @message = mb.perform
    Conversations::AssignOnAgentReplyService.new(
      conversation: @conversation,
      message: @message,
      user: user
    ).perform
    attach_canned_response_files if params[:canned_response_id].present?

    success_response(
      data: MessageSerializer.serialize(@message, include_attachments: true, include_sender: true),
      message: 'Message created successfully',
      status: :created
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Failed to create message',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  # Re-send selected WhatsApp messages to up to five contacts, with a randomized delay per delivery.
  def forward
    message_ids = Array(params[:message_ids]).map(&:to_s).uniq
    contact_ids = Array(params[:contact_ids]).map(&:to_s).uniq

    return invalid_forward_request('Select between 1 and 10 messages') unless message_ids.length.between?(1, 10)
    return invalid_forward_request('Select between 1 and 5 contacts') unless contact_ids.length.between?(1, 5)
    return invalid_forward_request('Forwarding is available only for WhatsApp conversations') unless @conversation.inbox.channel_type == 'Channel::Whatsapp'

    messages = @conversation.messages.where(id: message_ids).index_by { |item| item.id.to_s }
    return invalid_forward_request('One or more messages cannot be forwarded') unless messages.length == message_ids.length
    ineligible = messages.values.any? do |item|
      item.private? || item.activity? || item.template? || item.content_attributes&.dig('deleted') || item.content_attributes&.dig('revoked_by_contact')
    end
    return invalid_forward_request('Private, deleted, or system messages cannot be forwarded') if ineligible
    unavailable_media = messages.values.any? { |item| item.attachments.any? { |attachment| !attachment.file.attached? } }
    return invalid_forward_request('One or more message attachments are unavailable in the CRM') if unavailable_media

    contacts = Contact.where(id: contact_ids).index_by { |item| item.id.to_s }
    return invalid_forward_request('One or more contacts are unavailable') unless contacts.length == contact_ids.length
    return invalid_forward_request('All recipients must have a phone number') if contacts.values.any? { |contact| contact.phone_number.blank? }

    sender = Current.user || @resource
    return error_response(ApiErrorCodes::FORBIDDEN, 'An authenticated agent is required to forward messages', status: :forbidden) unless sender&.id

    delay = 5.seconds
    queued = 0
    message_ids.each do |message_id|
      contact_ids.each do |contact_id|
        Messages::ForwardMessageJob.set(wait: delay).perform_later(@conversation.id, message_id, contact_id, @conversation.inbox_id, sender.id)
        delay += rand(5..12).seconds
        queued += 1
      end
    end

    success_response(data: { queued: queued, contacts: contact_ids.length, messages: message_ids.length }, message: 'Messages queued for forwarding', status: :accepted)
  rescue StandardError => e
    error_response(ApiErrorCodes::VALIDATION_ERROR, 'Failed to queue forwarded messages', details: e.message, status: :unprocessable_entity)
  end

  def update
    @message = message
    previous_status = @message.status
    target_status = permitted_params[:status]
    return invalid_transition_response(previous_status, target_status) unless perform_status_update(target_status)

    success_response(
      data: MessageSerializer.serialize(@message.reload, include_attachments: true, include_sender: true),
      message: 'Message updated successfully'
    )
  rescue StandardError => e
    error_response(ApiErrorCodes::VALIDATION_ERROR, 'Failed to update message', details: e.message, status: :unprocessable_entity)
  end

  def destroy
    @message = message
    @message.update!(content_attributes: (@message.content_attributes || {}).merge(deleted: true))
    enqueue_provider_delete(@message)

    success_response(
      data: MessageSerializer.serialize(@message, include_attachments: true, include_sender: true),
      message: 'Message deleted successfully'
    )
  rescue ActiveRecord::RecordNotFound
    error_response(
      ApiErrorCodes::RESOURCE_NOT_FOUND,
      'Message not found',
      status: :not_found
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Failed to delete message',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  def retry
    @message = message

    claimed = @message.with_lock do
      next false unless @message.outgoing? && !@message.private? && @message.failed? && @message.source_id.blank?

      attrs = @message.content_attributes || {}
      @message.update!(
        status: :sent,
        content_attributes: attrs.except(
          'external_error', 'whatsapp_auto_retry_http_status', 'whatsapp_auto_retry_count', 'whatsapp_auto_retry_token'
        )
      )
      true
    end

    unless claimed
      return error_response(
        ApiErrorCodes::VALIDATION_ERROR,
        'Only failed, unsent public messages can be retried',
        status: :unprocessable_entity
      )
    end

    # The row lock above makes manual retry an atomic claim; a competing click
    # cannot enqueue/send the same failed row twice.
    ::SendReplyJob.perform_now(@message.id)

    success_response(
      data: MessageSerializer.serialize(@message.reload, include_attachments: true, include_sender: true),
      message: 'Message retry completed successfully'
    )
  rescue StandardError => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Failed to retry message',
      details: e.message,
      status: :unprocessable_entity
    )
  end

  private

  # EVO-1891: when an agent deletes an OUTGOING message, revoke it on the provider
  # (delete-for-everyone) where supported. Done in a background job so a slow or
  # unreachable provider never blocks/delays the CRM soft-delete response.
  def enqueue_provider_delete(message)
    return unless message.outgoing?

    channel = message.conversation&.inbox&.channel
    return unless channel.respond_to?(:delete_message)

    Whatsapp::DeleteMessageOnProviderJob.perform_later(message.id)
  end

  def perform_status_update(target_status)
    Messages::StatusUpdateService.new(@message, target_status, permitted_params[:external_error]).perform
  end

  def invalid_forward_request(message)
    error_response(ApiErrorCodes::INVALID_PARAMETER, message, status: :unprocessable_entity)
  end

  def invalid_transition_response(previous_status, target_status)
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Invalid status transition',
      details: "#{previous_status} → #{target_status}",
      status: :unprocessable_entity
    )
  end

  def message
    @message ||= @conversation.messages.find(permitted_params[:id])
  end

  def message_finder
    @message_finder ||= MessageFinder.new(@conversation, params, includes: message_includes)
  end

  def message_includes
    @message_includes ||= [
      :sender,
      :conversation,
      :inbox,
      :attachments
    ]
  end

  def permitted_params
    params.permit(:id, :status, :external_error)
  end

  # API inbox check
  def ensure_api_inbox
    # Only API inboxes can update messages
    return if @conversation.inbox.api?

    error_response(
      ApiErrorCodes::FORBIDDEN,
      'Message status update is only allowed for API inboxes',
      status: :forbidden
    )
  end

  def attach_canned_response_files
    canned = CannedResponse.find_by(id: params[:canned_response_id])
    return unless canned

    canned.attachments.find_each do |att|
      new_att = @message.attachments.build(
        file_type: att.file_type,
        extension: att.extension,
        fallback_title: att.fallback_title,
        meta: att.meta,
        external_url: att.external_url
      )

      # reuse the SAME blob from ActiveStorage (no re-upload)
      new_att.file.attach(att.file.blob) if att.file.attached?
      new_att.save!
    end
  end
end
