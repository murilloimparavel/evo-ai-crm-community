# frozen_string_literal: true

module BotRuntime
  # Validate source evidence under the conversation lock before a forced reply.
  class HandoffStaleness
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    def initialize(conversation, params)
      @conversation = conversation
      @params = params
    end

    def stale?
      return false unless @params.key?(:source_message_ids)
      return true if @conversation.resolved?

      ids = @params[:source_message_ids]
      return true unless valid_ids?(ids)

      ids = ids.uniq
      source = @conversation.messages.where(id: ids, message_type: :incoming)
      return true unless source.count == ids.size

      timestamp = source.maximum(:created_at)
      timestamp.nil? || later_public_message?(ids, timestamp)
    end

    private

    def valid_ids?(ids)
      ids.is_a?(Array) && ids.present? && ids.size <= 1000 &&
        ids.all? { |id| id.is_a?(String) && id.match?(UUID) }
    end

    # Equal timestamps are conservatively treated as potentially newer.
    def later_public_message?(ids, timestamp)
      @conversation.messages.where(private: false).where.not(id: ids).where('created_at >= ?', timestamp).exists?(
        ["(message_type = ? OR (message_type = ? AND COALESCE(sender_type, '') <> ?))",
         Message.message_types.fetch('incoming'), Message.message_types.fetch('outgoing'), 'AgentBot']
      )
    end
  end
end
