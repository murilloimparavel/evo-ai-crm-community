# frozen_string_literal: true

module KnowledgeRuntime
  # Resolve canonical database identity for an authenticated internal caller.
  # This primitive alone does not authorize tenant, session, delegation or replay.
  class DispatchIdentity
    class Denied < StandardError; end
    Identity = Struct.new(:conversation_id, :bot_id, :message_ids, keyword_init: true)
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    MAX_MESSAGES = 100

    def self.resolve(display_id:, bot_id:, message_ids:)
      validate_identity!(display_id, bot_id)
      validate_ids!(message_ids)
      conversation = Conversation.find_by(display_id: display_id)
      raise Denied, 'dispatch_denied' unless conversation

      validate_assignment!(conversation, bot_id)
      validate_messages!(conversation, message_ids)
      Identity.new(conversation_id: conversation.id.to_s, bot_id: bot_id, message_ids: message_ids.dup.freeze).freeze
    end

    def self.validate_identity!(display_id, bot_id)
      raise Denied, 'dispatch_denied' unless display_id.is_a?(Integer) && display_id.positive? && UUID.match?(bot_id.to_s)
    end

    def self.validate_ids!(ids)
      raise Denied, 'dispatch_denied' unless ids.is_a?(Array) && ids.any? && ids.length <= MAX_MESSAGES
      raise Denied, 'dispatch_denied' unless ids.all? { |id| valid_uuid?(id) } && ids.uniq.length == ids.length
    end

    def self.valid_uuid?(id)
      id.is_a?(String) && UUID.match?(id)
    end

    def self.validate_assignment!(conversation, bot_id)
      assignments = AgentBotInbox.where(inbox_id: conversation.inbox_id, status: :active).limit(2).to_a
      raise Denied, 'dispatch_denied' unless assignments.one? && assignments.first.agent_bot_id.to_s == bot_id
    end

    def self.validate_messages!(conversation, ids)
      messages = Message.where(id: ids, conversation_id: conversation.id, inbox_id: conversation.inbox_id).to_a
      raise Denied, 'dispatch_denied' unless messages.length == ids.length && messages.all? { |message| message.incoming? && !message.private? }
    end
    private_class_method :valid_uuid?, :validate_identity!, :validate_ids!, :validate_assignment!, :validate_messages!
  end
end
