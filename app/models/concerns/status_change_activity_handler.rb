module StatusChangeActivityHandler
  extend ActiveSupport::Concern

  include StatusChangeActivityContentHandler

  private

  def status_change_activity(user_name)
    status_change = saved_change_to_status
    return if status_change.blank?

    from_status, to_status = status_change
    event_id = SecureRandom.uuid
    actor = status_change_activity_actor(user_name, Current.executed_by)
    message_params = status_activity_message_params(from_status, to_status, actor, event_id)
    enqueue_status_activity(message_params, from_status, to_status, actor.first, event_id)
  rescue StandardError => e
    log_status_activity_failure(from_status, to_status, e)
    raise
  end

  def status_activity_message_params(from_status, to_status, actor, event_id)
    actor_type, actor_name, actor_id, execution_source = actor
    content = status_change_activity_content(to_status, actor_type, actor_name, Current.executed_by)
    activity_message_params(content).merge(
      activity_event_id: event_id,
      content_attributes: {
        status_change: {
          event_id: event_id,
          from: from_status.to_s,
          to: to_status.to_s,
          actor: { type: actor_type, id: actor_id, name: actor_name },
          execution_source: execution_source
        }
      }
    )
  end

  def enqueue_status_activity(message_params, from_status, to_status, actor_type, event_id)
    job, enqueue_error = enqueue_status_activity_job(message_params)
    return log_status_activity_enqueued(job, from_status, to_status, actor_type, event_id) if status_activity_enqueued?(job)

    log_status_activity_rejected(job, enqueue_error, from_status, to_status, actor_type, event_id)
    persist_status_activity_fallback(message_params, event_id)
  end

  def enqueue_status_activity_job(message_params)
    [::Conversations::ActivityMessageJob.perform_later(self, message_params), nil]
  rescue StandardError => e
    [nil, e]
  end

  def status_activity_enqueued?(job)
    job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?
  end

  def log_status_activity_enqueued(job, from_status, to_status, actor_type, event_id)
    Rails.logger.info(
      "[ConversationActivity] status_change_enqueued conversation_id=#{id} " \
      "event_id=#{event_id} from=#{from_status} to=#{to_status} actor_type=#{actor_type} job_id=#{job.job_id}"
    )
  end

  def log_status_activity_rejected(job, error, from_status, to_status, actor_type, event_id)
    Rails.logger.error(
      "[ConversationActivity] status_change_enqueue_rejected conversation_id=#{id} " \
      "event_id=#{event_id} from=#{from_status} to=#{to_status} actor_type=#{actor_type} " \
      "job_id=#{job&.job_id} error=#{error&.class}"
    )
  end

  def persist_status_activity_fallback(message_params, event_id)
    message = ::Conversations::ActivityMessageJob.perform_now(self, message_params)
    Rails.logger.info(
      "[ConversationActivity] status_change_fallback_persisted conversation_id=#{id} " \
      "event_id=#{event_id} message_id=#{message.id}"
    )
  end

  def log_status_activity_failure(from_status, to_status, error)
    Rails.logger.error(
      "[ConversationActivity] status_change_activity_failed conversation_id=#{id} " \
      "from=#{from_status} to=#{to_status} error=#{error.class}"
    )
  end
end
