module PriorityActivityMessageHandler
  extend ActiveSupport::Concern

  private

  def priority_change_activity(user_name)
    old_priority, new_priority = previous_changes.values_at('priority')[0]
    return unless priority_change?(old_priority, new_priority)

    user = activity_message_owner(user_name)
    content = build_priority_change_content(user, old_priority, new_priority)
    event = activity_event_payload(
      action: 'priority_changed',
      actor_name: user,
      target: { type: 'conversation', id: id.to_s },
      changes: { from: old_priority, to: new_priority }
    )

    enqueue_activity_event(content, event)
  end

  def priority_change?(old_priority, new_priority)
    old_priority.present? || new_priority.present?
  end

  def build_priority_change_content(user_name, old_priority = nil, new_priority = nil)
    change_type = get_priority_change_type(old_priority, new_priority)

    I18n.t("conversations.activity.priority.#{change_type}", user_name: user_name, new_priority: new_priority, old_priority: old_priority)
  end

  def get_priority_change_type(old_priority, new_priority)
    case [old_priority.present?, new_priority.present?]
    when [true, true] then 'updated'
    when [false, true] then 'added'
    when [true, false] then 'removed'
    end
  end
end
