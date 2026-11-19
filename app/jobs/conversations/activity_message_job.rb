class Conversations::ActivityMessageJob < ApplicationJob
  queue_as :high

  def perform(conversation, message_params)
    message_params = message_params.with_indifferent_access
    message = persist_activity_message(conversation, message_params)
    log_activity_persisted(conversation, message, message_params[:activity_event_id])
    message
  rescue StandardError => e
    log_activity_failure(conversation, message_params, e)
    raise
  end

  private

  def persist_activity_message(conversation, message_params)
    activity_event_id = message_params[:activity_event_id]
    return conversation.messages.create!(message_params) if activity_event_id.blank?

    conversation.messages.create_or_find_by!(activity_event_id: activity_event_id) do |record|
      record.assign_attributes(message_params.except(:activity_event_id))
    end
  end

  def log_activity_persisted(conversation, message, event_id)
    Rails.logger.info(
      "[ActivityMessageJob] persisted conversation_id=#{conversation.id} message_id=#{message.id} " \
      "message_type=#{message.message_type} event_id=#{event_id} job_id=#{job_id}"
    )
  end

  def log_activity_failure(conversation, message_params, error)
    Rails.logger.error(
      "[ActivityMessageJob] failed conversation_id=#{conversation&.id} " \
      "message_type=#{message_params[:message_type]} event_id=#{message_params[:activity_event_id]} " \
      "error=#{error.class} job_id=#{job_id}"
    )
  end
end
