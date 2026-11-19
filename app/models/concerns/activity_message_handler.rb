module ActivityMessageHandler
  extend ActiveSupport::Concern

  include PriorityActivityMessageHandler
  include LabelActivityMessageHandler
  include TeamActivityMessageHandler
  include BotHandoffActivityMessageHandler
  include StatusChangeActivityHandler

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

  def activity_message_params(content, activity_event: nil)
    params = { inbox_id: inbox_id, message_type: :activity, content: content }
    return params unless activity_event

    params[:activity_event_id] = activity_event[:event_id]
    params[:content_attributes] = { activity_event: activity_event }

    actor = activity_event[:actor]
    if %w[user agent_bot].include?(actor[:type]) && Current.user&.id.to_s == actor[:id]
      params[:sender] = Current.user
    end

    params
  end

  def activity_event_payload(action:, actor_name:, target:, changes: nil, event_id: SecureRandom.uuid, actor: nil)
    payload = {
      event_id: event_id,
      action: action,
      actor: actor || activity_event_actor(actor_name),
      target: target
    }
    payload[:changes] = changes if changes.present?

    caused_by = activity_event_cause
    payload[:caused_by] = caused_by if caused_by.present?
    payload
  end

  def activity_event_actor(actor_name)
    if Current.executed_by.is_a?(AutomationRule)
      return {
        type: 'automation', id: Current.executed_by.id.to_s, name: Current.executed_by.name,
        display_name: I18n.t('automation.system_name'), source: Current.executed_by.class.name
      }
    end

    contact = Current.executed_by.is_a?(Contact) ? Current.executed_by : Current.contact
    if contact.present?
      return { type: 'contact', id: contact.id.to_s, name: contact.name, source: contact.class.name }
    end

    if Current.user.present? && actor_name.to_s == Current.user.name.to_s
      type = Current.user.is_a?(AgentBot) ? 'agent_bot' : 'user'
      return { type: type, id: Current.user.id.to_s, name: Current.user.name, source: Current.user.class.name }
    end

    {
      type: 'system', id: nil, name: actor_name.presence || I18n.t('automation.system_name'),
      source: activity_event_execution_source
    }
  end

  def activity_event_execution_source
    executed_by = Current.executed_by
    return 'system' if executed_by.blank?
    return executed_by.to_s if executed_by.is_a?(Symbol)

    executed_by.class.name
  end

  def activity_event_cause
    executed_by = Current.executed_by
    return if executed_by.blank?

    case executed_by
    when AutomationRule
      { type: 'automation', id: executed_by.id.to_s, name: executed_by.name }
    when Contact
      { type: 'contact', id: executed_by.id.to_s, name: executed_by.name }
    else
      { type: 'system', id: nil, name: activity_event_execution_source }
    end
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
    event = activity_event_payload(
      action: change_type == 'muted' ? 'conversation_muted' : 'conversation_unmuted',
      actor_name: Current.user.name,
      target: { type: 'conversation', id: id.to_s },
      changes: { muted: change_type == 'muted' }
    )
    ::Conversations::ActivityMessageJob.perform_later(self, activity_message_params(content, activity_event: event)) if content
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
    old_assignee_id, new_assignee_id = previous_changes.fetch('assignee_id', [assignee_id, assignee_id])
    actor_name = user_name
    action = new_assignee_id.present? ? 'assignee_assigned' : 'assignee_removed'
    event = activity_event_payload(
      action: action,
      actor_name: actor_name,
      target: { type: 'user', id: (new_assignee_id || old_assignee_id)&.to_s, name: new_assignee_id.present? ? assignee&.name : User.find_by(id: old_assignee_id)&.name },
      changes: { from: old_assignee_id&.to_s, to: new_assignee_id&.to_s }
    )
    ::Conversations::ActivityMessageJob.perform_later(self, activity_message_params(content, activity_event: event)) if content
  end

  def activity_message_owner(user_name)
    return user_name if user_name.present?

    I18n.t('automation.system_name')
  end
end

ActivityMessageHandler.prepend_mod_with('ActivityMessageHandler')
