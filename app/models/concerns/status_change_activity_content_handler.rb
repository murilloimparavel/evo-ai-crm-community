module StatusChangeActivityContentHandler
  extend ActiveSupport::Concern

  private

  def auto_resolve_message_key(minutes)
    return { key: 'auto_resolved_days', count: minutes / 1440 } if minutes >= 1440 && (minutes % 1440).zero?
    return { key: 'auto_resolved_hours', count: minutes / 60 } if minutes >= 60 && (minutes % 60).zero?

    { key: 'auto_resolved_minutes', count: minutes }
  end

  def status_change_activity_actor(user_name, executed_by)
    return automation_activity_actor(executed_by) if executed_by.is_a?(AutomationRule)
    return contact_activity_actor(executed_by) if executed_by.is_a?(Contact)
    return contact_activity_actor(Current.contact) if Current.contact.present?
    return user_activity_actor(user_name) if user_name.present?

    system_activity_actor(executed_by)
  end

  def automation_activity_actor(rule)
    ['automation', I18n.t('automation.system_name'), rule.id, rule.class.name]
  end

  def contact_activity_actor(contact)
    name = contact.name.presence || I18n.t('automation.system_name')
    ['contact', name, contact.id, contact.class.name]
  end

  def user_activity_actor(name)
    ['user', name, Current.user&.id, Current.user&.class&.name]
  end

  def system_activity_actor(executed_by)
    # Unknown execution sources still need a visible timeline entry.
    source_name = executed_by.is_a?(Symbol) ? executed_by.to_s : executed_by&.class&.name
    ['system', I18n.t('automation.system_name'), nil, source_name]
  end

  def status_change_activity_content(to_status, actor_type, actor_name, executed_by)
    return contact_resolved_content(actor_name) if actor_type == 'contact' && to_status.to_s == 'resolved'
    return contact_open_content(executed_by) if actor_type == 'contact' && to_status.to_s == 'open'
    return auto_resolved_content if auto_resolved_status?(to_status, actor_type, executed_by)

    I18n.t("conversations.activity.status.#{to_status}", user_name: actor_name)
  end

  def contact_resolved_content(actor_name)
    I18n.t('conversations.activity.status.contact_resolved', contact_name: actor_name.capitalize)
  end

  def contact_open_content(executed_by)
    # Preserve the loop guard for contact-triggered reopen events.
    Current.executed_by = nil if executed_by.is_a?(Contact)
    I18n.t('conversations.activity.status.system_auto_open')
  end

  def auto_resolved_status?(to_status, actor_type, executed_by)
    actor_type == 'system' && to_status.to_s == 'resolved' && executed_by.nil? && auto_resolve_after.present?
  end

  def auto_resolved_content
    message_data = auto_resolve_message_key(auto_resolve_after)
    I18n.t("conversations.activity.status.#{message_data[:key]}", count: message_data[:count])
  end
end
