class Conversations::UrgentUnansweredService
  def initialize(conversation)
    @conversation = conversation
  end

  def process
    source_message = update_queue
    return unless source_message && source_message.created_at > 24.hours.ago

    bot_inbox = eligible_bot_inbox
    return unless bot_inbox

    AgentBots::InactivityActionsService.new(@conversation, bot_inbox.agent_bot).process_urgent_followup(source_message)
  end

  private

  def update_queue
    @conversation.with_lock do
      source_message = @conversation.messages.incoming.where(private: false)
                                    .reorder(created_at: :desc, id: :desc).first
      if eligible?(source_message)
        mark_urgent(source_message)
        source_message
      else
        clear_urgent
        nil
      end
    end
  end

  def eligible?(source_message)
    return false unless @conversation.live? && source_message&.live?
    return false unless active_conversation?
    return false unless source_message.created_at.between?(2.days.ago, 2.minutes.ago)

    !public_reply_after?(source_message)
  end

  def active_conversation?
    (@conversation.open? || @conversation.pending?) && @conversation.custom_attributes&.dig('archived').to_s != 'true'
  end

  def public_reply_after?(source_message)
    @conversation.messages.where(message_type: %i[outgoing template], private: false)
                 .exists?(['created_at >= ?', source_message.created_at])
  end

  def eligible_bot_inbox
    bot_inbox = @conversation.inbox.agent_bot_inbox
    return unless bot_inbox&.active?

    bot = bot_inbox.agent_bot
    bot_inbox if bot&.evo_ai_provider? && bot.outgoing_url.present?
  end

  def mark_urgent(source_message)
    attributes = (@conversation.custom_attributes || {}).dup
    return if attributes['urgent_followup'] && attributes['urgent_followup_message_id'] == source_message.id

    attributes['urgent_followup'] = true
    attributes['urgent_followup_message_id'] = source_message.id
    @conversation.update!(custom_attributes: attributes)
  end

  def clear_urgent
    attributes = (@conversation.custom_attributes || {}).dup
    return unless attributes['urgent_followup']

    attributes.delete('urgent_followup')
    attributes.delete('urgent_followup_message_id')
    @conversation.update!(custom_attributes: attributes)
  end
end
