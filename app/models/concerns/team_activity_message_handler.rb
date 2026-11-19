module TeamActivityMessageHandler
  extend ActiveSupport::Concern

  private

  def create_team_change_activity(user_name)
    user_name = activity_message_owner(user_name)
    return unless user_name

    content = team_activity_content(user_name)
    event = team_activity_event(user_name)
    enqueue_activity_event(content, event)

    # A team assignment activity includes the new assignee in its localized
    # text. Changes that remove or clear an assignee still need their own event.
    create_assignee_change_activity(user_name) if unrepresented_assignee_change?
  end

  def team_activity_content(user_name)
    key = generate_team_change_activity_key
    params = { assignee_name: assignee&.name, team_name: team&.name, user_name: user_name }
    params[:team_name] = generate_team_name_for_activity if key == 'removed'
    I18n.t("conversations.activity.team.#{key}", **params)
  end

  def team_activity_event(user_name)
    old_team_id, new_team_id = previous_changes.fetch('team_id', [team_id, team_id])
    action = new_team_id.present? ? 'team_assigned' : 'team_removed'
    target_name = new_team_id.present? ? team&.name : generate_team_name_for_activity
    activity_event_payload(
      action: action,
      actor_name: user_name,
      target: { type: 'team', id: (new_team_id || old_team_id)&.to_s, name: target_name },
      changes: team_activity_changes(old_team_id, new_team_id)
    )
  end

  def unrepresented_assignee_change?
    return false unless saved_change_to_assignee_id?

    team_id.blank? || assignee.blank?
  end

  def team_activity_changes(old_team_id, new_team_id)
    changes = { team: { from: old_team_id&.to_s, to: new_team_id&.to_s } }
    return changes unless saved_change_to_assignee_id?

    old_assignee_id, new_assignee_id = previous_changes.fetch('assignee_id')
    changes[:assignee] = {
      from: activity_user_reference(old_assignee_id),
      to: activity_user_reference(new_assignee_id)
    }
    changes
  end

  def activity_user_reference(user_id)
    { id: user_id&.to_s, name: User.find_by(id: user_id)&.name }
  end

  def generate_team_change_activity_key
    team = Team.find_by(id: team_id)
    key = team.present? ? 'assigned' : 'removed'
    key += '_with_assignee' if key == 'assigned' && saved_change_to_assignee_id? && assignee
    key
  end

  def generate_team_name_for_activity
    previous_team_id = previous_changes[:team_id][0]
    Team.find_by(id: previous_team_id)&.name if previous_team_id.present?
  end
end
