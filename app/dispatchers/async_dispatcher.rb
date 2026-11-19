class AsyncDispatcher < BaseDispatcher
  def dispatch(event_name, timestamp, data)
    job = EventDispatcherJob.perform_later(event_name, timestamp, data)
    return job unless conversation_status_event?(event_name)

    log_conversation_event_enqueue(event_name, data, job)
    job
  rescue StandardError => e
    log_conversation_event_enqueue_failure(event_name, data, e) if conversation_status_event?(event_name)
    raise
  end

  def publish_event(event_name, timestamp, data)
    event_object = Events::Base.new(event_name, timestamp, data)
    publish(event_object.method_name, event_object)
  end

  def listeners
    [
      AutomationRuleListener.instance,
      CsatSurveyListener.instance,
      HookListener.instance,
      InstallationWebhookListener.instance,
      NotificationListener.instance,
      ParticipationListener.instance,
      PipelineStageAutomationListener.instance,
      PipelineTaskListener.instance,
      StageInactivityResetListener.instance,
      ReportingEventListener.instance,
      WebhookListener.instance,
      ChannelListener.instance,
      WhatsappSyncListener.instance,
      ZapiSyncListener.instance
    ]
  end

  private

  def conversation_status_event?(event_name)
    %w[
      conversation_updated conversation_status_changed conversation_resolved conversation_opened
      conversation.updated conversation.status_changed conversation.resolved conversation.opened
    ].include?(event_name.to_s)
  end

  def conversation_id_from_event(data)
    conversation = data[:conversation] || data['conversation'] if data.respond_to?(:[])
    conversation&.id || data[:conversation_id] || data['conversation_id'] if data.respond_to?(:[])
  end

  def log_conversation_event_enqueue(event_name, data, job)
    status = job&.successfully_enqueued? ? 'enqueued' : 'enqueue_rejected'
    Rails.logger.public_send(status == 'enqueued' ? :info : :error,
                             "[EventDispatcher] #{status} event=#{event_name} conversation_id=#{conversation_id_from_event(data)} job_id=#{job&.job_id}")
  end

  def log_conversation_event_enqueue_failure(event_name, data, error)
    Rails.logger.error(
      "[EventDispatcher] enqueue_failed event=#{event_name} conversation_id=#{conversation_id_from_event(data)} error=#{error.class}"
    )
  end
end

AsyncDispatcher.prepend_mod_with('AsyncDispatcher')
