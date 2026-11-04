# frozen_string_literal: true

require 'digest'

module KnowledgeRuntime
  # Internal primitive only: the caller must authenticate the conversation,
  # account, executing agent and delegation. No caller-controlled scope or
  # agent identifier is an authorization credential. Not exposed as an API.
  class Retrieval
    class InvalidRequest < StandardError; end

    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    MAX_QUERY = 500
    MAX_BODY = 4_000

    def self.call(account_scope:, agent_id:, query:, limit: 5)
      validate!(account_scope, agent_id, query, limit)

      # A single SQL statement selects current bindings, base status and entry
      # status within the same database snapshot, before ranking and limiting.
      entries = KnowledgeEntry.search_published(query.strip, limit: limit)
                              .joins(knowledge_base: :knowledge_agent_bindings)
                              .where(account_scope: account_scope)
                              .where(knowledge_bases: { account_scope: account_scope, status: 'active' })
                              .where(knowledge_agent_bindings: { account_scope: account_scope,
                                                                 external_agent_id: agent_id, enabled: true })
                              .to_a
      entries.map do |entry|
        { id: entry.id, knowledge_base_id: entry.knowledge_base_id, title: entry.title,
          body: entry.body.first(MAX_BODY), content_type: entry.content_type,
          source: entry.source, updated_at: entry.updated_at,
          base_version: entry.knowledge_base.lock_version, body_sha256: Digest::SHA256.hexdigest(entry.body),
          source_updated_at: entry.updated_at.iso8601(6) }
      end
    end

    def self.validate!(account_scope, agent_id, query, limit)
      raise InvalidRequest unless account_scope.is_a?(String) && account_scope.present?
      raise InvalidRequest unless agent_id.to_s.match?(UUID)

      validate_query!(query)
      raise InvalidRequest unless limit.is_a?(Integer) && limit.between?(1, 10)
    end

    def self.validate_query!(query)
      raise InvalidRequest unless query.is_a?(String) && query.strip.present? && query.length <= MAX_QUERY
    end
    private_class_method :validate!, :validate_query!
  end
end
