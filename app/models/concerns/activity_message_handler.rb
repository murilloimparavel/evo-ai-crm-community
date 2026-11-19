module ActivityMessageHandler
  extend ActiveSupport::Concern

  include PriorityActivityMessageHandler
  include LabelActivityMessageHandler
  include TeamActivityMessageHandler
  include BotHandoffActivityMessageHandler
  include StatusChangeActivityHandler
  include ActivityEventMetadataHandler

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
    params[:sender] = Current.user if activity_event_sender?(actor)

    params
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
    enqueue_activity_event(content, event)
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
    event = assignee_activity_event(user_name)
    enqueue_activity_event(content, event)
  end

  def assignee_activity_event(user_name)
    old_id, new_id = previous_changes.fetch('assignee_id', [assignee_id, assignee_id])
    assigned = new_id.present?
    action = assigned ? 'assignee_assigned' : 'assignee_removed'
    target_name = assigned ? assignee&.name : User.find_by(id: old_id)&.name
    target = { type: 'user', id: (new_id || old_id)&.to_s, name: target_name }
    activity_event_payload(
      action: action,
      actor_name: user_name,
      target: target,
      changes: assignee_id_changes(old_id, new_id)
    )
  end

  def assignee_id_changes(old_id, new_id)
    { from: old_id&.to_s, to: new_id&.to_s }
  end

  def activity_message_owner(user_name)
    return I18n.t('automation.system_name') if Current.executed_by.is_a?(AutomationRule)

    contact = Current.executed_by.is_a?(Contact) ? Current.executed_by : Current.contact
    return contact.name if contact.present?
    return user_name if user_name.present?

    I18n.t('automation.system_name')
  end
end

ActivityMessageHandler.prepend_mod_with('ActivityMessageHandler')
