# frozen_string_literal: true

module KnowledgeRuntime
  # Resolve database identity from the Bot Runtime's display ID and real source
  # messages. Only an authenticated internal caller may invoke this. This is a
  # validation primitive, not proof of tenant, session, delegation or replay.
  class DispatchIdentity
    class Denied < StandardError; end
    Identity = Struct.new(:conversation_id, :bot_id, :message_ids, keyword_init: true)
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.freeze
    MAX_MESSAGES = 100

    def self.resolve(display_id:, bot_id:, message_ids:)
      raise Denied, 'dispatch_denied' unless display_id.is_a?(Integer) && display_id.positive? &&
                                             UUID.match?(bot_id.to_s) && message_ids.is_a?(Array) &&
                                             message_ids.any? && message_ids.length <= MAX_MESSAGES &&
                                             message_ids.all? { |id| id.is_a?(String) && UUID.match?(id) } &&
                                             message_ids.uniq.length == message_ids.length

      conversation = Conversation.find_by(display_id: display_id)
      raise Denied, 'dispatch_denied' unless conversation

      assignments = AgentBotInbox.where(inbox_id: conversation.inbox_id, status: :active).limit(2).to_a
      raise Denied, 'dispatch_denied' unless assignments.one? && assignments.first.agent_bot_id.to_s == bot_id

      messages = Message.where(id: message_ids, conversation_id: conversation.id, inbox_id: conversation.inbox_id).to_a
      raise Denied, 'dispatch_denied' unless messages.length == message_ids.length &&
                                             messages.all? { |message| message.incoming? && !message.private? }

      Identity.new(conversation_id: conversation.id.to_s, bot_id: bot_id, message_ids: message_ids.dup.freeze).freeze
    end
  end
end
