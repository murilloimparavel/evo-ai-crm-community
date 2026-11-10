# frozen_string_literal: true

module KnowledgeRuntime
  class ProvenanceHistory
    def self.enrich(history, token:, executor_token:)
      return history unless ENV['KNOWLEDGE_RESPONSE_PROVENANCE_ENABLED'] == 'true' && executor_token.present?

      ApplicationRecord.transaction(isolation: :repeatable_read) do
        executor, grant = context!(token, executor_token)
        typed, sources, omitted = authorized_turns(messages(grant), grant, executor)
        validate_size!(typed)

        revision = profile_revision(grant, executor)
        history.merge(profile_revision: revision, typed_turns: typed, provenance_sources: sources.uniq, history_incomplete: omitted)
      end
    rescue ResponseProvenance::Denied, ActiveRecord::RecordNotFound, ActiveRecord::TransactionIsolationError
      raise CustomerHistory::Denied
    end

    def self.profile_revision(grant, executor)
      KnowledgeAgentAccessProfile.find_by(account_scope: grant['account_scope'], external_agent_id: executor['agent_id'])&.revision || 0
    end

    def self.validate_size!(typed)
      raise CustomerHistory::Denied if typed.empty? || typed.sum { |turn| turn[:text].length } > 100_000
    end

    def self.context!(token, executor_token)
      executor, grant = ResponseProvenance.decode(executor_token, 'knowledge-history-executor')
      actual = CustomerHistory.verified_claims(token)
      raise CustomerHistory::Denied unless %w[jti account_scope conversation_id event_id root_agent_id].all? { |key| actual[key] == grant[key] }

      [executor, grant]
    end

    def self.messages(grant)
      event = Message.find_by!(id: grant['event_id'], conversation_id: grant['conversation_id'])
      messages = Message.where(conversation_id: event.conversation_id, inbox_id: event.inbox_id, private: false, content_type: :text)
                        .where('created_at <= ?', event.created_at).reorder(created_at: :desc).limit(100).to_a.reverse
      raise CustomerHistory::Denied unless messages.map(&:created_at).uniq.length == messages.length

      messages.select { |message| CustomerHistory.visible_message?(message) }
    end

    def self.authorized_turns(messages, grant, executor)
      sources = []
      omitted = false
      typed = messages.filter_map do |message|
        next { role: 'user', text: message.content } if message.incoming? && message.content.present?
        next unless message.outgoing?

        record = KnowledgeResponseProvenance.find_by(message_id: message.id)
        if record && ResponseProvenance.reusable?(record, grant, executor)
          sources.concat(record.sources)
          { role: 'assistant', text: message.content }
        else
          omitted = true
          nil
        end
      end
      [typed, sources, omitted]
    end
    private_class_method :profile_revision, :validate_size!, :context!, :messages, :authorized_turns
  end
end
