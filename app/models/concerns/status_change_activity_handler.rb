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
    context = status_activity_context(from_status, to_status, actor.first, event_id)
    enqueue_status_activity(message_params, context)
  rescue StandardError => e
    log_status_activity_failure(from_status, to_status, e)
    raise
  end

  def status_activity_message_params(from_status, to_status, actor, event_id)
    actor_type, actor_name, _, execution_source = actor
    content = status_change_activity_content(to_status, actor_type, actor_name, Current.executed_by)
    activity_event = status_activity_event(from_status, to_status, actor, event_id)
    status_change = status_change_attributes(event_id, from_status, to_status, actor, execution_source)
    activity_message_params(content, activity_event: activity_event).merge(
      content_attributes: { activity_event: activity_event, status_change: status_change }
    )
  end

  def status_activity_event(from_status, to_status, actor, event_id)
    actor_type, actor_name, actor_id, execution_source = actor
    event = activity_event_payload(
      action: 'status_changed', actor_name: actor_name, event_id: event_id,
      target: { type: 'conversation', id: id.to_s },
      changes: { from: from_status.to_s, to: to_status.to_s }
    )
    event[:actor] = status_activity_event_actor(actor_type, actor_name, actor_id, execution_source)
    event
  end

  def status_activity_event_actor(actor_type, actor_name, actor_id, execution_source)
    return activity_event_actor(actor_name) if Current.executed_by.is_a?(AutomationRule)

    { type: actor_type, id: actor_id&.to_s, name: actor_name, source: execution_source }
  end

  def status_change_attributes(event_id, from_status, to_status, actor, execution_source)
    actor_type, actor_name, actor_id, = actor
    {
      event_id: event_id,
      from: from_status.to_s,
      to: to_status.to_s,
      actor: { type: actor_type, id: actor_id, name: actor_name },
      execution_source: execution_source
    }
  end

  def enqueue_status_activity(message_params, context)
    job, enqueue_error = enqueue_status_activity_job(message_params)
    return log_status_activity_enqueued(job, context) if status_activity_enqueued?(job)

    log_status_activity_rejected(job, enqueue_error, context)
    persist_status_activity_fallback(message_params, context[:event_id])
  end

  def status_activity_context(from_status, to_status, actor_type, event_id)
    { from_status: from_status, to_status: to_status, actor_type: actor_type, event_id: event_id }
  end

  def enqueue_status_activity_job(message_params)
    [::Conversations::ActivityMessageJob.perform_later(self, message_params), nil]
  rescue StandardError => e
    [nil, e]
  end

  def status_activity_enqueued?(job)
    job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?
  end

  def log_status_activity_enqueued(job, context)
    Rails.logger.info(
      "[ConversationActivity] status_change_enqueued conversation_id=#{id} " \
      "event_id=#{context[:event_id]} from=#{context[:from_status]} to=#{context[:to_status]} " \
      "actor_type=#{context[:actor_type]} job_id=#{job.job_id}"
    )
  end

  def log_status_activity_rejected(job, error, context)
    Rails.logger.error(
      "[ConversationActivity] status_change_enqueue_rejected conversation_id=#{id} " \
      "event_id=#{context[:event_id]} from=#{context[:from_status]} to=#{context[:to_status]} " \
      "actor_type=#{context[:actor_type]} " \
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
