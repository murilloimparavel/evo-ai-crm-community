# frozen_string_literal: true

module KnowledgeRuntime
  # Explicit operational attestation, not tenant metadata from Core. Only use
  # when Core is dedicated to the same single Community account as this CRM.
  # Enterprise and unconfigured installations must fail closed.
  class CommunityAgentAuthority
    class Unavailable < StandardError; end
    class UnknownAgent < StandardError; end

    def self.verify!(account_scope:, agent_id:, request_headers:)
      raise Unavailable unless attested_scope?(account_scope)
      raise UnknownAgent unless agent_id.to_s.match?(BindingSet::UUID)

      agent = EvoAiCoreService.get_agent(agent_id, request_headers)
      raise UnknownAgent unless agent.is_a?(Hash) && agent['id'].to_s.downcase == agent_id.downcase

      true
    rescue ActiveRecord::RecordNotFound
      raise UnknownAgent
    rescue UnknownAgent, Unavailable
      raise
    rescue StandardError
      raise Unavailable
    end

    def self.attested_scope?(account_scope)
      dedicated_scope = ENV['KNOWLEDGE_CORE_DEDICATED_ACCOUNT_SCOPE'].to_s
      extensions = %i[runtime_context_current_id runtime_context_with_scope].any? { |name| EvoExtensionPoints.impl_for(name) }
      configured_scope = (RuntimeConfig.account&.dig('id').presence || 'community').to_s
      dedicated_scope.present? && !extensions && account_scope == dedicated_scope && account_scope == configured_scope
    end
    private_class_method :attested_scope?
  end
end
