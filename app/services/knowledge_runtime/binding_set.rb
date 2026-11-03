# frozen_string_literal: true

module KnowledgeRuntime
  # Storage primitive only. Callers must independently authenticate the user,
  # authorize the scope and agent against Core, and check both permissions.
  # It is intentionally not exposed through a controller until Core can prove
  # that the agent belongs to the authenticated scope.
  class BindingSet
    class RevisionConflict < StandardError; end
    class InvalidSelection < StandardError; end

    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    MAX_BASES = 100

    def self.replace!(account_scope:, agent_id:, base_ids:, expected_revision:, user_id:)
      unless account_scope.is_a?(String) && account_scope.present? && agent_id.to_s.match?(UUID) &&
             base_ids.is_a?(Array) && base_ids.length <= MAX_BASES &&
             base_ids.all? { |id| id.is_a?(String) && id.match?(UUID) } &&
             base_ids.map(&:downcase).uniq.length == base_ids.length &&
             expected_revision.is_a?(Integer) && expected_revision >= 0 && user_id.present?
        raise InvalidSelection
      end

      ids = base_ids.map(&:downcase).sort
      KnowledgeAgentAccessProfile.transaction do
        now = Time.current
        KnowledgeAgentAccessProfile.insert_all(
          [{ account_scope: account_scope, external_agent_id: agent_id, revision: 0, created_at: now, updated_at: now }],
          unique_by: :idx_knowledge_agent_profile
        )
        profile = KnowledgeAgentAccessProfile.lock.find_by!(account_scope: account_scope, external_agent_id: agent_id)
        raise RevisionConflict unless profile.revision == expected_revision

        bases = KnowledgeBase.where(account_scope: account_scope, status: 'active', id: ids).order(:id).lock.to_a
        raise InvalidSelection unless bases.map { |base| base.id.to_s.downcase }.sort == ids

        bindings = KnowledgeAgentBinding.where(account_scope: account_scope, external_agent_id: agent_id)
        bindings.where.not(knowledge_base_id: ids).destroy_all
        existing = bindings.index_by { |binding| binding.knowledge_base_id.to_s.downcase }
        bases.each do |base|
          binding = existing[base.id.to_s.downcase]
          if binding
            binding.update!(enabled: true, updated_by_id: user_id) unless binding.enabled?
          else
            bindings.create!(knowledge_base: base, enabled: true, created_by_id: user_id, updated_by_id: user_id)
          end
        end
        profile.update!(revision: profile.revision + 1)
        profile.revision
      end
    end
  end
end
