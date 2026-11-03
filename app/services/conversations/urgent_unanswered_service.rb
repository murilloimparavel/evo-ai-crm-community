class Conversations::UrgentUnansweredService
  def initialize(conversation)
    @conversation = conversation
  end

  def process
    source_message = nil

    @conversation.with_lock do
      source_message = @conversation.messages.incoming.where(private: false)
                                    .order(created_at: :desc, id: :desc).first
      unanswered = @conversation.live? && source_message&.live? &&
                   source_message.created_at >= 2.days.ago &&
                   source_message.created_at <= 2.minutes.ago &&
                   !@conversation.messages.where(message_type: %i[outgoing template], private: false)
                                 .where('created_at >= ?', source_message.created_at).exists?
      attributes = (@conversation.custom_attributes || {}).dup
      if unanswered && (@conversation.open? || @conversation.pending?) && attributes['archived'].to_s != 'true'
        next if attributes['urgent_followup'] && attributes['urgent_followup_message_id'] == source_message.id

        attributes['urgent_followup'] = true
        attributes['urgent_followup_message_id'] = source_message.id
      else
        next unless attributes['urgent_followup']

        attributes.delete('urgent_followup')
        attributes.delete('urgent_followup_message_id')
        source_message = nil
      end
      @conversation.update!(custom_attributes: attributes)
    end

    return unless source_message
    return unless source_message.created_at > 24.hours.ago

    bot_inbox = @conversation.inbox.agent_bot_inbox
    return unless bot_inbox&.active? && bot_inbox.agent_bot&.evo_ai_provider? &&
                  bot_inbox.agent_bot.outgoing_url.present?

    AgentBots::InactivityActionsService.new(@conversation, bot_inbox.agent_bot).process_urgent_followup(source_message)
  end
end
