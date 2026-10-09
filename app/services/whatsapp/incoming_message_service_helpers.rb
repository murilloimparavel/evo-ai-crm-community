module Whatsapp::IncomingMessageServiceHelpers
  def download_attachment_file(attachment_payload)
    Down.download(inbox.channel.media_url(attachment_payload[:id]), headers: inbox.channel.api_headers)
  end

  def conversation_params
    {
      inbox_id: @inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id
    }
  end

  def processed_params
    @processed_params ||= params
  end

  def message_type
    if evolution_api?
      # Evolution API structure: data.messageType
      payload_value(@processed_params, :data, :messageType)
    else
      # Baileys structure: messages.first.type
      payload_value(@processed_params, :messages)&.first&.then { |message| payload_value(message, :type) }
    end
  end

  def message_content(message)
    content = payload_value(message, :text, :body) ||
              payload_value(message, :button, :text) ||
              payload_value(message, :interactive, :button_reply, :title) ||
              payload_value(message, :interactive, :list_reply, :title) ||
              payload_value(message, :interactive, :nfm_reply, :body) ||
              payload_value(message, :interactive, :list_reply, :description) ||
              payload_value(message, :interactive, :button_reply, :description) ||
              payload_value(message, :name, :formatted_name)

    return content if content.present?

    message_type = payload_value(message, :type)
    case message_type
    when 'image' then 'Imagem recebida'
    when 'audio' then 'Áudio recebido'
    when 'video' then 'Vídeo recebido'
    when 'contacts' then contacts_message_content(payload_value(message, :contacts))
    when 'document' then payload_value(message, :document, :filename).presence || 'Documento recebido'
    when 'sticker' then 'Figurinha recebida'
    when 'location' then location_message_content(payload_value(message, :location))
    when 'reaction' then reaction_message_content(payload_value(message, :reaction))
    when 'order' then order_message_content(payload_value(message, :order))
    when 'system' then system_message_content(payload_value(message, :system))
    when 'unknown' then unknown_message_content(payload_value(message, :errors))
    else
      message_type.present? ? "Mensagem do WhatsApp (#{message_type})" : 'Mensagem do WhatsApp recebida'
    end
  end

  def location_message_content(location)
    return 'Localização recebida' if location.blank?

    name = [payload_value(location, :name), payload_value(location, :address)].select(&:present?).join(', ')
    name.presence || 'Localização recebida'
  end

  def contacts_message_content(contacts)
    names = Array(contacts).each_with_object([]) do |contact, collected_names|
      name = payload_value(contact, :name, :formatted_name).presence
      collected_names << name if name
    end
    names.any? ? "Contato recebido: #{names.first(3).join(', ')}" : 'Contato recebido'
  end

  def payload_value(payload, *keys)
    keys.reduce(payload) do |value, key|
      break nil if value.nil?

      value[key] || value[key.to_s]
    end
  rescue TypeError, NoMethodError
    nil
  end

  def reaction_message_content(reaction)
    emoji = payload_value(reaction, :emoji).presence
    emoji ? "Reagiu com #{emoji}" : 'Reação recebida'
  end

  def order_message_content(order)
    products = Array(payload_value(order, :product_items))
    return 'Pedido do catálogo recebido' if products.empty?

    product_names = products.first(3).each_with_object([]) do |product, names|
      product_id = payload_value(product, :product_retailer_id).presence
      quantity = payload_value(product, :quantity).presence
      next unless product_id

      names << (quantity ? "#{product_id} (#{quantity})" : product_id)
    end
    summary = product_names.any? ? ": #{product_names.join(', ')}" : ''
    remaining = products.size - product_names.size
    summary += " e mais #{remaining}" if remaining.positive?
    "Pedido do catálogo recebido (#{products.size} #{products.size == 1 ? 'item' : 'itens'})#{summary}"
  end

  def system_message_content(system)
    return 'Atualização do WhatsApp recebida' if system.blank?

    case payload_value(system, :type)
    when 'customer_changed_number' then 'O contato informou uma alteração no número do WhatsApp'
    else 'Atualização do WhatsApp recebida'
    end
  end

  def unknown_message_content(errors)
    error = Array(errors).first || {}
    code = payload_value(error, :code).presence
    code ? "Mensagem do WhatsApp não suportada (código #{code})" : 'Mensagem do WhatsApp não suportada'
  end

  def file_content_type(file_type)
    return :image if %w[image sticker].include?(file_type)
    return :audio if %w[audio voice].include?(file_type)
    return :video if ['video'].include?(file_type)
    return :location if ['location'].include?(file_type)
    return :contact if ['contacts'].include?(file_type)

    :file
  end

  def unprocessable_message_type?(message_type)
    %w[ephemeral unsupported request_welcome].include?(message_type)
  end

  def brazil_phone_number?(phone_number)
    phone_number.match(/^55/)
  end

  # ref: https://github.com/evolution/evolution/issues/5840
  def normalised_brazil_mobile_number(phone_number)
    # DDD : Area codes in Brazil are popularly known as "DDD codes" (códigos DDD) or simply "DDD", from the initials of "direct distance dialing"
    # https://en.wikipedia.org/wiki/Telephone_numbers_in_Brazil
    ddd = phone_number[2, 2]
    # Remove country code and DDD to obtain the number
    number = phone_number[4, phone_number.length - 4]
    normalised_number = "55#{ddd}#{number}"
    # insert 9 to convert the number to the new mobile number format
    normalised_number = "55#{ddd}9#{number}" if normalised_number.length != 13
    normalised_number
  end

  def processed_waid(waid)
    return waid if waid.blank? || bsuid_format?(waid)

    # in case of Brazil, we need to do additional processing
    # https://github.com/evolution/evolution/issues/5840
    if brazil_phone_number?(waid)
      # check if there is an existing contact inbox with the normalised waid
      # We will create conversation against it
      contact_inbox = inbox.contact_inboxes.find_by(source_id: normalised_brazil_mobile_number(waid))

      # if there is no contact inbox with the waid without 9,
      # We will create contact inboxes and contacts with the number 9 added
      waid = contact_inbox.source_id if contact_inbox.present?
    end
    waid
  end

  def bsuid_format?(value)
    value.present? && value.match?(RegexHelper::BSUID_REGEX)
  end

  def error_webhook_event?(message)
    payload_value(message, :errors).present?
  end

  def log_error(message)
    errors = payload_value(message, :errors)
    error = Array(errors).first || {}
    type = payload_value(message, :type)
    code = payload_value(error, :code)
    # Provider titles and contact identifiers can contain user data. Keep the
    # diagnostic useful without logging message text, phone numbers, or tokens.
    Rails.logger.warn("WhatsApp webhook reported an error (type=#{type}, code=#{code || 'unknown'})")
  end

  def process_in_reply_to(message)
    @in_reply_to_external_id = payload_value(message, :context, :id)
  end

  def find_message_by_source_id(source_id)
    return unless source_id

    @message = Message.find_by(source_id: source_id)
  end

  def message_under_process?
    message_id = if evolution_api?
                   # Evolution API structure: data.key.id
                   @processed_params[:data]&.dig(:key, :id)
                 else
                   # Baileys structure: messages.first.id
                   @processed_params[:messages]&.first&.dig(:id)
                 end

    return false unless message_id

    key = format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: message_id)
    Redis::Alfred.get(key)
  end

  def cache_message_source_id_in_redis
    message_id = if evolution_api?
                   # Evolution API structure: data.key.id
                   @processed_params[:data]&.dig(:key, :id)
                 else
                   # Baileys structure: messages.first.id
                   return if @processed_params.try(:[], :messages).blank?

                   @processed_params[:messages].first[:id]
                 end

    return unless message_id

    key = format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: message_id)
    ::Redis::Alfred.setex(key, true)
  end

  def clear_message_source_id_from_redis
    message_id = if evolution_api?
                   # Evolution API structure: data.key.id
                   @processed_params[:data]&.dig(:key, :id)
                 else
                   # Baileys structure: messages.first.id
                   @processed_params[:messages].first[:id]
                 end

    return unless message_id

    key = format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: message_id)
    ::Redis::Alfred.delete(key)
  rescue StandardError => e
    # Callers release the guard from an `ensure`, where a raise here would replace the
    # exception already propagating and hide why the message failed in the first place.
    Rails.logger.error "Whatsapp: failed to clear the dedup guard for #{message_id}: #{e.message}"
  end

  private

  def evolution_api?
    # Evolution API has data structure with event field, while Baileys has messages array
    @processed_params[:data].present? && @processed_params[:event].present?
  end
end
