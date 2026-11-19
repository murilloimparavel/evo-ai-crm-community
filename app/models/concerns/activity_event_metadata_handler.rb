module ActivityEventMetadataHandler
  extend ActiveSupport::Concern

  private

  def activity_event_payload(action:, actor_name:, target:, changes: nil, event_id: SecureRandom.uuid)
    payload = { event_id: event_id, action: action, actor: activity_event_actor(actor_name), target: target }
    payload[:changes] = changes if changes.present?
    cause = activity_event_cause
    payload[:caused_by] = cause if cause.present?
    payload
  end

  def enqueue_activity_event(content, activity_event)
    return if content.blank?

    params = activity_message_params(content, activity_event: activity_event)
    ::Conversations::ActivityMessageJob.perform_later(self, params)
  end

  def activity_event_sender?(actor)
    %w[user agent_bot].include?(actor[:type]) && Current.user&.id.to_s == actor[:id]
  end

  def activity_event_actor(actor_name)
    return automation_event_actor if Current.executed_by.is_a?(AutomationRule)

    contact = activity_event_contact
    return contact_event_actor(contact) if contact.present?

    user = Current.user
    return user_event_actor(user) if user.present? && actor_name.to_s == user.name.to_s

    system_event_actor(actor_name)
  end

  def automation_event_actor
    rule = Current.executed_by
    { type: 'automation', id: rule.id.to_s, name: rule.name,
      display_name: I18n.t('automation.system_name'), source: rule.class.name }
  end

  def activity_event_contact
    return Current.executed_by if Current.executed_by.is_a?(Contact)

    Current.contact
  end

  def contact_event_actor(contact)
    { type: 'contact', id: contact.id.to_s, name: contact.name, source: contact.class.name }
  end

  def user_event_actor(user)
    type = user.is_a?(AgentBot) ? 'agent_bot' : 'user'
    { type: type, id: user.id.to_s, name: user.name, source: user.class.name }
  end

  def system_event_actor(actor_name)
    { type: 'system', id: nil, name: actor_name.presence || I18n.t('automation.system_name'),
      source: activity_event_execution_source }
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
    return { type: 'automation', id: executed_by.id.to_s, name: executed_by.name } if executed_by.is_a?(AutomationRule)
    return { type: 'contact', id: executed_by.id.to_s, name: executed_by.name } if executed_by.is_a?(Contact)

    { type: 'system', id: nil, name: activity_event_execution_source }
  end
end
