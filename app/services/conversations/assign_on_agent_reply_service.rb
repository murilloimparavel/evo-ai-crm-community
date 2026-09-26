class Conversations::AssignOnAgentReplyService
  pattr_initialize [:conversation!, :message!, :user!]

  def perform
    return unless eligible_reply?

    conversation.with_lock do
      next if conversation.assignee_id.present?

      conversation.update!(assignee: user)
    end
  end

  private

  def eligible_reply?
    return false unless user.is_a?(User) && user.agent?
    return false unless message.outgoing? && !message.private?
    return false unless conversation.inbox.members.exists?(id: user.id)
    return false if conversation.team.present? && !conversation.team.members.exists?(id: user.id)

    conversation.inbox.auto_assignment_config&.dig('assign_on_agent_reply') == true
  end
end
