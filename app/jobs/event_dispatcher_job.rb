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
    return unless conversation_status_event?(event_name)

    Rails.logger.public_send(log_level(error_class), conversation_event_log_line(state, event_name, data, error_class))
  end

  def conversation_status_event?(event_name)
    %w[
      conversation_updated conversation_status_changed conversation_resolved conversation_opened
      conversation.updated conversation.status_changed conversation.resolved conversation.opened
    ].include?(event_name.to_s)
  end

  def log_level(error_class)
    error_class ? :error : :info
  end

  def conversation_event_log_line(state, event_name, data, error_class)
    details = "[EventDispatcher] #{state} event=#{event_name} " \
              "conversation_id=#{conversation_id_from_event(data)} job_id=#{job_id}"
    error_class ? "#{details} error=#{error_class}" : details
  end

  def conversation_id_from_event(data)
    return unless data.respond_to?(:[])

    conversation = data[:conversation] || data['conversation']
    conversation&.id || data[:conversation_id] || data['conversation_id']
  end
end
