# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/

class Whatsapp::IncomingMessageWhatsappCloudService < Whatsapp::IncomingMessageBaseService
  private

  def processed_params
    @processed_params ||= params[:entry].try(:first).try(:[], 'changes').try(:first).try(:[], 'value')
  end

  def download_attachment_file(attachment_payload)
    media_id = payload_value(attachment_payload, :id)
    raise MediaDownloadError, 'media ID missing from webhook' if media_id.blank?

    url_response = HTTParty.get(inbox.channel.media_url(media_id), headers: inbox.channel.api_headers)
    # This url response will be failure if the access token has expired.
    if url_response.unauthorized?
      inbox.channel.authorization_error!
      raise MediaDownloadError, 'media authorization rejected'
    end
    raise MediaDownloadError, "media metadata request returned HTTP #{url_response.code}" unless url_response.success?

    media_metadata = url_response.parsed_response
    media_url = media_metadata.is_a?(Hash) ? payload_value(media_metadata, :url) : nil
    raise MediaDownloadError, 'media URL missing from metadata response' if media_url.blank?

    Down.download(media_url, headers: inbox.channel.api_headers)
  rescue StandardError => e
    # Webhook retries must not turn a media-fetch issue into a lost message or
    # an empty inbox bubble. Never log the exception message: HTTP clients may
    # include signed media URLs or authorization details in it.
    Rails.logger.warn("[WHATSAPP] Cloud media download failed (type=#{message_type}, error=#{e.class})")
    if @message
      attachment_payload = payload_value(@processed_params[:messages].first, message_type.to_sym)
      caption = payload_value(attachment_payload, :caption)
      @message.content = media_download_failure_content(message_type) if caption.blank?
      @message.content_attributes = (@message.content_attributes || {}).merge(
        media_download_failed: true,
        media_download_error: e.class.name
      )
    end
    nil
  end

  class MediaDownloadError < StandardError; end
end
