module ActivityMessageHandler
  extend ActiveSupport::Concern

  include PriorityActivityMessageHandler
  include LabelActivityMessageHandler
  include TeamActivityMessageHandler
  include BotHandoffActivityMessageHandler

  private

  def create_activity
    user_name = determine_user_name

    handle_status_change(user_name)
    handle_priority_change(user_name)
    handle_label_change(user_name)
  end

  def determine_user_name
    Current.user&.name
  end

  def handle_status_change(user_name)
    return unless saved_change_to_status?

    status_change_activity(user_name)
  end

  def handle_priority_change(user_name)
    return unless saved_change_to_priority?

    priority_change_activity(user_name)
  end

  def handle_label_change(user_name)
    return unless saved_change_to_label_list?

    create_label_change(activity_message_owner(user_name))
  end

  def handle_sla_policy_change(user_name)
    return unless saved_change_to_sla_policy_id?

    sla_change_type = determine_sla_change_type
    create_sla_change_activity(sla_change_type, activity_message_owner(user_name))
  end

  def status_change_activity(user_name)
    from_status = nil
    to_status = nil
    status_change = saved_change_to_status
    return if status_change.blank?

    from_status, to_status = status_change
    executed_by = Current.executed_by
    actor_type, actor_name, actor_id, execution_source = status_change_activity_actor(user_name, executed_by)
    content = status_change_activity_content(to_status, actor_type, actor_name, executed_by)
    activity_event_id = SecureRandom.uuid
    message_params = activity_message_params(content).merge(
      activity_event_id: activity_event_id,
      content_attributes: {
        status_change: {
          event_id: activity_event_id,
          from: from_status.to_s,
          to: to_status.to_s,
          actor: { type: actor_type, id: actor_id, name: actor_name },
          execution_source: execution_source
        }
      }
    )

    enqueue_error = nil
    job = begin
      ::Conversations::ActivityMessageJob.perform_later(self, message_params)
    rescue StandardError => e
      enqueue_error = e
      nil
    end

    if job&.successfully_enqueued?
      Rails.logger.info(
        "[ConversationActivity] status_change_enqueued conversation_id=#{id} " \
        "event_id=#{activity_event_id} from=#{from_status} to=#{to_status} " \
        "actor_type=#{actor_type} job_id=#{job.job_id}"
      )
    else
      Rails.logger.error(
        "[ConversationActivity] status_change_enqueue_rejected conversation_id=#{id} " \
        "event_id=#{activity_event_id} from=#{from_status} to=#{to_status} " \
        "actor_type=#{actor_type} job_id=#{job&.job_id} error=#{enqueue_error&.class}"
      )
      message = ::Conversations::ActivityMessageJob.perform_now(self, message_params)
      Rails.logger.info(
        "[ConversationActivity] status_change_fallback_persisted conversation_id=#{id} " \
        "event_id=#{activity_event_id} message_id=#{message.id}"
      )
    end
  rescue StandardError => e
    Rails.logger.error(
      "[ConversationActivity] status_change_activity_failed conversation_id=#{id} " \
      "from=#{from_status} to=#{to_status} error=#{e.class}"
    )
    raise
  end

  def auto_resolve_message_key(minutes)
    if minutes >= 1440 && (minutes % 1440).zero?
      { key: 'auto_resolved_days', count: minutes / 1440 }
    elsif minutes >= 60 && (minutes % 60).zero?
      { key: 'auto_resolved_hours', count: minutes / 60 }
    else
      { key: 'auto_resolved_minutes', count: minutes }
    end
  end

  def status_change_activity_actor(user_name, executed_by)
    if executed_by.is_a?(AutomationRule)
      ['automation', I18n.t('automation.system_name'), executed_by.id, executed_by.class.name]
    elsif executed_by.is_a?(Contact)
      ['contact', executed_by.name.presence || I18n.t('automation.system_name'), executed_by.id, executed_by.class.name]
    elsif Current.contact.present?
      ['contact', Current.contact.name.presence || I18n.t('automation.system_name'), Current.contact.id, Current.contact.class.name]
    elsif user_name.present?
      ['user', user_name, Current.user&.id, Current.user&.class&.name]
    else
      # Unknown execution sources (for example :stage_automation) still need a
      # visible timeline entry instead of silently dropping the status change.
      source_name = executed_by.is_a?(Symbol) ? executed_by.to_s : executed_by&.class&.name
      ['system', I18n.t('automation.system_name'), nil, source_name]
    end
  end

  def status_change_activity_content(to_status, actor_type, actor_name, executed_by)
    if actor_type == 'contact' && to_status.to_s == 'resolved'
      I18n.t('conversations.activity.status.contact_resolved', contact_name: actor_name.capitalize)
    elsif actor_type == 'contact' && to_status.to_s == 'open'
      # Preserve the existing loop guard for contact-triggered reopen events.
      Current.executed_by = nil if executed_by.is_a?(Contact)
      I18n.t('conversations.activity.status.system_auto_open')
    elsif actor_type == 'system' && to_status.to_s == 'resolved' && executed_by.nil? && auto_resolve_after.present?
      message_data = auto_resolve_message_key(auto_resolve_after)
      I18n.t("conversations.activity.status.#{message_data[:key]}", count: message_data[:count])
    else
      I18n.t("conversations.activity.status.#{to_status}", user_name: actor_name)
    end
  end

  def activity_message_params(content)
    { inbox_id: inbox_id, message_type: :activity, content: content }
  end

  def create_muted_message
    create_mute_change_activity('muted')
  end

  def create_unmuted_message
    create_mute_change_activity('unmuted')
  end

  def create_mute_change_activity(change_type)
    return unless Current.user

    content = I18n.t("conversations.activity.#{change_type}", user_name: Current.user.name)
    ::Conversations::ActivityMessageJob.perform_later(self, activity_message_params(content)) if content
  end

  def generate_assignee_change_activity_content(user_name)
    params = { assignee_name: assignee&.name, user_name: user_name }.compact
    key = assignee_id ? 'assigned' : 'removed'
    key = 'self_assigned' if self_assign? assignee_id
    I18n.t("conversations.activity.assignee.#{key}", **params)
  end

  def create_assignee_change_activity(user_name)
    user_name = activity_message_owner(user_name)

    return unless user_name

    content = generate_assignee_change_activity_content(user_name)
    ::Conversations::ActivityMessageJob.perform_later(self, activity_message_params(content)) if content
  end

  def activity_message_owner(user_name)
    user_name = I18n.t('automation.system_name') if !user_name && Current.executed_by.present?
    user_name
  end
end

ActivityMessageHandler.prepend_mod_with('ActivityMessageHandler')
