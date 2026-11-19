class Conversations::ActivityMessageJob < ApplicationJob
  queue_as :high

  def perform(conversation, message_params)
    message_params = message_params.with_indifferent_access
    activity_event_id = message_params[:activity_event_id]
    message = if activity_event_id.present?
                conversation.messages.create_or_find_by!(activity_event_id: activity_event_id) do |record|
                  record.assign_attributes(message_params.except(:activity_event_id))
                end
              else
                conversation.messages.create!(message_params)
              end
    Rails.logger.info(
      "[ActivityMessageJob] persisted conversation_id=#{conversation.id} message_id=#{message.id} " \
      "message_type=#{message.message_type} event_id=#{activity_event_id} job_id=#{job_id}"
    )
    message
  rescue StandardError => e
    Rails.logger.error(
      "[ActivityMessageJob] failed conversation_id=#{conversation&.id} " \
      "message_type=#{message_params[:message_type]} event_id=#{message_params[:activity_event_id]} " \
      "error=#{e.class} job_id=#{job_id}"
    )
    raise
  end
end
