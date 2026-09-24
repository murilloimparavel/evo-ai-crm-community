class Whatsapp::RetryRateLimitedMessageJob < ApplicationJob
  queue_as :high

  def perform(message_id, attempt)
    message = Message.find_by(id: message_id)
    return unless message

    claimed = message.with_lock do
      attrs = message.content_attributes || {}
      eligible = message.outgoing? && !message.private? && message.failed? &&
                 message.source_id.blank? && attrs['whatsapp_auto_retry_count'].to_i == attempt &&
                 attrs['whatsapp_auto_retry_http_status'].to_i == 429
      next false unless eligible

      message.update!(
        status: :sent,
        content_attributes: attrs.except('external_error')
      )
      true
    end
    return unless claimed

    SendReplyJob.perform_now(message.id)
  end
end
