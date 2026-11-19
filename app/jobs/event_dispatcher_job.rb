class EventDispatcherJob < ApplicationJob
  queue_as :critical

  def perform(event_name, timestamp, data)
    log_conversation_event('started', event_name, data)
    result = Rails.configuration.dispatcher.async_dispatcher.publish_event(event_name, timestamp, data)
    log_conversation_event('completed', event_name, data)
    result
  rescue StandardError => e
    log_conversation_event('failed', event_name, data, e.class)
    raise
  end

  private

  def log_conversation_event(state, event_name, data, error_class = nil)
    return unless %w[
      conversation_updated conversation_status_changed conversation_resolved conversation_opened
      conversation.updated conversation.status_changed conversation.resolved conversation.opened
    ].include?(event_name.to_s)

    conversation = data[:conversation] || data['conversation'] if data.respond_to?(:[])
    conversation_id = conversation&.id || data[:conversation_id] || data['conversation_id'] if data.respond_to?(:[])
    details = "[EventDispatcher] #{state} event=#{event_name} conversation_id=#{conversation_id} job_id=#{job_id}"
    details += " error=#{error_class}" if error_class
    Rails.logger.public_send(error_class ? :error : :info, details)
  end
end
