# Mostly modeled after the intial implementation of the service based on 360 Dialog
# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/
class Whatsapp::IncomingMessageBaseService
  include ::Whatsapp::IncomingMessageServiceHelpers

  pattr_initialize [:inbox!, :params!]

  def perform
    processed_params

    if processed_params.try(:[], :statuses).present?
      process_statuses
    elsif processed_params.try(:[], :messages).present?
      process_messages
    end
  end

  private

  def process_messages
    # WhatsApp Cloud API Coexistence sends delete-for-everyone as a `revoke`
    # message in the standard messages webhook. It identifies the original
    # message via revoke.original_message_id; it is not a new chat message.
    return process_revoked_message if message_type == 'revoke'

    # Ephemeral wrappers and service-only requests do not represent a customer
    # message. Reactions and unknown payloads are persisted with a readable
    # fallback so the inbox never renders an unexplained empty bubble.
    return if unprocessable_message_type?(message_type)

    # Multiple webhook event can be received against the same message due to misconfigurations in the Meta
    # business manager account. While we have not found the core reason yet, the following line ensure that
    # there are no duplicate messages created.
    message_id = payload_value(@processed_params[:messages].first, :id)
    return if find_message_by_source_id(message_id) || message_under_process?

    cache_message_source_id_in_redis

    begin
      set_contact
      return unless @contact

      set_conversation
      create_messages
    ensure
      clear_message_source_id_from_redis
    end
  end

  def process_revoked_message
    message = @processed_params[:messages].first
    original_message_id = payload_value(message, :revoke, :original_message_id)
    return if original_message_id.blank?

    mark_message_revoked_by_source_id(original_message_id)
  end

  def process_statuses
    return unless find_message_by_source_id(@processed_params[:statuses].first[:id])

    update_message_with_status(@message, @processed_params[:statuses].first)
    persist_bsuid_from_status
  rescue ArgumentError => e
    Rails.logger.error "Error while processing whatsapp status update #{e.message}"
  end

  def persist_bsuid_from_status
    return unless @message&.conversation&.contact_inbox

    contact_inbox = @message.conversation.contact_inbox

    # Status webhooks now include contacts[] with user_id and recipient_user_id
    bsuid = @processed_params.dig(:contacts, 0, :user_id) ||
            @processed_params[:statuses]&.first&.dig(:recipient_user_id)
    username = @processed_params.dig(:contacts, 0, :profile, :username)

    update_bsuid_fields(contact_inbox, bsuid, username)
  rescue StandardError => e
    Rails.logger.error "Error persisting BSUID from status webhook: #{e.message}"
  end

  def update_message_with_status(message, status)
    status_name = status[:status]
    external_error = nil
    if status_name == 'failed' && status[:errors].present?
      error = status[:errors].first
      external_error = "#{error[:code]}: #{error[:title]}"
    end
    Messages::StatusUpdateService.new(message, status_name, external_error).perform
  end

  def create_messages
    message = @processed_params[:messages].first
    if error_webhook_event?(message)
      log_error(message)
      return unless payload_value(message, :type) == 'unknown'
    end

    process_in_reply_to(message)

    message_type == 'contacts' ? create_contact_messages(message) : create_regular_message(message)
  end

  def create_contact_messages(message)
    (payload_value(message, :contacts) || []).each do |contact|
      create_message(contact)
      attach_contact(contact)
      @message.save!
    end
  end

  def create_regular_message(message)
    create_message(message)
    attach_files
    attach_location if message_type == 'location'
    @message.save!
  end

  def set_contact
    contact_params = @processed_params[:contacts]&.first
    return if contact_params.blank?

    bsuid = contact_params[:user_id]
    username = contact_params.dig(:profile, :username)
    waid = contact_params[:wa_id]
    phone_from = @processed_params[:messages]&.first&.dig(:from)

    if waid.present?
      # Phone available: use existing flow
      source_id = processed_waid(waid)
      phone_number = "+#{phone_from}" if phone_from.present?
    elsif bsuid.present?
      # BSUID-only: try to find existing contact_inbox by bsuid column first
      existing_ci = inbox.contact_inboxes.find_by(bsuid: bsuid)
      if existing_ci
        @contact_inbox = existing_ci
        @contact = existing_ci.contact
        update_bsuid_fields(existing_ci, bsuid, username)
        return
      end
      source_id = bsuid
      phone_number = nil
    else
      return
    end

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: source_id,
      inbox: inbox,
      contact_attributes: { name: contact_params.dig(:profile, :name), phone_number: phone_number }
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    # Always persist BSUID and username when present
    update_bsuid_fields(contact_inbox, bsuid, username)
  end

  def update_bsuid_fields(contact_inbox, bsuid, username)
    return unless bsuid.present? || username.present?

    attrs = {}
    attrs[:bsuid] = bsuid if bsuid.present? && contact_inbox.bsuid != bsuid
    attrs[:whatsapp_username] = username if username.present? && contact_inbox.whatsapp_username != username
    contact_inbox.update!(attrs) if attrs.present?
  rescue ActiveRecord::RecordNotUnique
    # Another contact_inbox on this inbox owns the bsuid and keeps owning it (the same
    # person reached us twice, once by phone JID and once by LID). Drop it from the
    # write so the remaining attributes still land instead of being lost with it.
    contact_inbox.restore_attributes
    Rails.logger.warn(
      "WhatsApp: bsuid=#{bsuid} already claimed by another contact_inbox - " \
      "keeping contact_inbox=#{contact_inbox.id} without it"
    )
    remaining = attrs.except(:bsuid)
    contact_inbox.update!(remaining) if remaining.present?
  end

  def set_conversation
    # Primeiro: busca conversation existente
    @conversation = if @inbox.lock_to_single_conversation
                      @contact_inbox.conversations.last
                    else
                      @contact_inbox.conversations
                                    .where.not(status: :resolved).last
                    end
    return if @conversation  # ← Se encontrou, retorna

    # Segundo: se não encontrou, cria nova usando operação atômica
    # find_or_create_by é mais seguro que create! para evitar race conditions
    @conversation = ::Conversation.find_or_create_by!(conversation_params)
  end

  def attach_files
    return if %w[text button interactive location contacts reaction order system unknown].include?(message_type)

    attachment_payload = payload_value(@processed_params[:messages].first, message_type.to_sym)
    return unless attachment_payload

    caption = payload_value(attachment_payload, :caption)
    @message.content = caption if caption.present?

    attachment_file = download_attachment_file(attachment_payload)
    if attachment_file.blank?
      @message.content = media_download_failure_content(message_type) if caption.blank?
      @message.content_attributes = (@message.content_attributes || {}).merge(media_download_failed: true)
      return
    end

    @message.attachments.new(
      file_type: file_content_type(message_type),
      file: {
        io: attachment_file,
        filename: attachment_file.original_filename,
        content_type: attachment_file.content_type
      }
    )
  end

  def attach_location
    message = @processed_params[:messages].first
    location = payload_value(message, :location) || {}
    location_name = [payload_value(location, :name), payload_value(location, :address)].select(&:present?).join(', ')
    @message.attachments.new(
      file_type: file_content_type(message_type),
      coordinates_lat: payload_value(location, :latitude),
      coordinates_long: payload_value(location, :longitude),
      fallback_title: location_name.presence,
      external_url: payload_value(location, :url)
    )
  end

  def create_message(message)
    message_type = payload_value(message, :type)
    content_attributes = {}
    @in_reply_to_external_id = nil
    if message_type == 'reaction'
      content_attributes[:is_reaction] = true
      content_attributes[:in_reply_to_external_id] = payload_value(message, :reaction, :message_id)
      @in_reply_to_external_id = content_attributes[:in_reply_to_external_id]
    end

    content = message_content(message)
    if content.blank? && message_type == 'unknown'
      content = media_download_failure_content('unknown')
      content_attributes[:is_unsupported] = true
    end
    @message = @conversation.messages.build(
      content: content.presence || (message_type == 'unknown' ? 'Mensagem do WhatsApp não suportada' : 'Mensagem do WhatsApp recebida'),
      inbox_id: @inbox.id,
      message_type: :incoming,
      sender: @contact,
      source_id: payload_value(message, :id).to_s,
      in_reply_to_external_id: @in_reply_to_external_id,
      content_attributes: content_attributes
    )
    @message.content = media_download_failure_content(message_type) if %w[image audio video document sticker].include?(message_type) && @message.content.blank?
  end

  def media_download_failure_content(type)
    label = {
      'image' => 'imagem',
      'audio' => 'áudio',
      'video' => 'vídeo',
      'document' => 'documento',
      'sticker' => 'figurinha'
    }.fetch(type, 'arquivo')
    "Não foi possível carregar o #{label} recebido."
  end

  def attach_contact(contact)
    phones = contact[:phones]
    phones = [{ phone: 'Phone number is not available' }] if phones.blank?

    phones.each do |phone|
      @message.attachments.new(
        file_type: file_content_type(message_type),
        fallback_title: phone[:phone].to_s
      )
    end
  end

  # Marks an existing inbound message as revoked-by-contact (the contact deleted
  # it on WhatsApp). The content is kept; the frontend shows a "deleted by
  # contact" notice. Reused across providers (evolution / evolution_go).
  def mark_message_revoked_by_source_id(source_id)
    return false if source_id.blank?

    message = inbox.messages.find_by(source_id: source_id.to_s)
    return false unless message
    # Only the contact can revoke their own (incoming) messages. Guards against the
    # provider echoing our own outbound delete-for-everyone back as a fromMe delete,
    # which would otherwise mislabel the agent's message as "deleted by contact".
    return false unless message.incoming?
    return true if message.revoked_by_contact

    message.revoked_by_contact = true
    message.save!
    Rails.logger.info "WhatsApp revoke: marked message #{message.id} (source_id #{source_id}) as revoked_by_contact"
    true
  end

  def revoked_message_source_id(protocol_message)
    return if protocol_message.blank?

    key = protocol_message[:key] || protocol_message[:Key] || {}
    key[:id] || key[:ID]
  end

end
