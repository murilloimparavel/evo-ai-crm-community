class Instagram::SendOnInstagramService < Instagram::BaseSendService
  private

  def channel_class
    Channel::Instagram
  end

  # Deliver a message with the given payload.
  # https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/messaging-api
  def send_message(message_content)
    instagram_id = channel.instagram_id.presence || 'me'
    url = "#{MetaBaseUrl.for(:instagram)}/#{instagram_id}/messages"

    response = if MetaBaseUrl.enabled?
                 send_via_evolution_hub(url, message_content)
               else
                 HTTParty.post(
                   url,
                   body: message_content,
                   query: { access_token: channel.access_token }
                 )
               end

    return if response.nil?

    process_response(response, message_content)
  end

  def send_via_evolution_hub(url, message_content)
    channel_token = ::EvolutionHub::ChannelReconciler.hub_channel_token_of(channel)

    if channel_token.blank? && channel.respond_to?(:heal_from_hub_if_stale!)
      channel.heal_from_hub_if_stale!
      channel_token = ::EvolutionHub::ChannelReconciler.hub_channel_token_of(channel)
    end

    if channel_token.blank?
      error = 'EVOLUTION_HUB_CHANNEL_TOKEN_MISSING'
      Rails.logger.error("Instagram proxy request not sent: #{error}")
      Messages::StatusUpdateService.new(message, 'failed', error).perform
      return nil
    end

    HTTParty.post(
      url,
      body: message_content,
      headers: {
        'Authorization' => "Bearer #{channel_token}",
        'Content-Type' => 'application/json'
      }
    )
  end

  def merge_human_agent_tag(params)
    global_config = GlobalConfig.get('ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT')

    return params unless global_config['ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT']

    params[:messaging_type] = 'MESSAGE_TAG'
    params[:tag] = 'HUMAN_AGENT'
    params
  end
end
