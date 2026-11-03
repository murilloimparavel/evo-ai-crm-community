# frozen_string_literal: true

module KnowledgeRuntime
  # Callers authenticate the actor and independently authorize the account and
  # agent. This primitive replaces the aggregate under one profile lock.
  class BindingSet
    class RevisionConflict < StandardError; end
    class InvalidSelection < StandardError; end

    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    MAX_BASES = 100

    def self.replace!(account_scope:, agent_id:, base_ids:, expected_revision:, user_id:)
      validate_identity!(account_scope, agent_id, user_id)
      raise InvalidSelection unless expected_revision.is_a?(Integer) && expected_revision >= 0

      ids = canonical_ids!(base_ids)
      KnowledgeAgentAccessProfile.transaction do
        profile = locked_profile!(account_scope, agent_id)
        raise RevisionConflict unless profile.revision == expected_revision

        bases = selected_bases!(account_scope, ids)
        replace_bindings!(account_scope, agent_id, bases, ids, user_id)
        profile.update!(revision: profile.revision + 1)
        profile.revision
      end
    end

    def self.validate_identity!(scope, agent_id, user_id)
      raise InvalidSelection unless scope.is_a?(String) && scope.present? && agent_id.to_s.match?(UUID) && user_id.present?
    end

    def self.canonical_ids!(base_ids)
      raise InvalidSelection unless base_ids.is_a?(Array) && base_ids.length <= MAX_BASES
      raise InvalidSelection unless base_ids.all? { |id| valid_uuid?(id) }

      ids = base_ids.map(&:downcase).sort
      raise InvalidSelection unless ids.uniq.length == ids.length

      ids
    end

    def self.valid_uuid?(id)
      id.is_a?(String) && id.match?(UUID)
    end

    def self.locked_profile!(scope, agent_id)
      now = Time.current
      # Validated identity plus the unique DB index make bootstrap atomic. A
      # uniqueness validation on create_or_find_by! would race before INSERT.
      KnowledgeAgentAccessProfile.insert_all( # rubocop:disable Rails/SkipsModelValidations
        [{ account_scope: scope, external_agent_id: agent_id, revision: 0, created_at: now, updated_at: now }],
        unique_by: :idx_knowledge_agent_profile
      )
      KnowledgeAgentAccessProfile.lock.find_by!(account_scope: scope, external_agent_id: agent_id)
    end

    def self.selected_bases!(scope, ids)
      bases = KnowledgeBase.where(account_scope: scope, status: 'active', id: ids).order(:id).lock.to_a
      raise InvalidSelection unless bases.map { |base| base.id.to_s.downcase }.sort == ids

      bases
    end

    def self.replace_bindings!(scope, agent_id, bases, ids, user_id)
      bindings = KnowledgeAgentBinding.where(account_scope: scope, external_agent_id: agent_id)
      bindings.where.not(knowledge_base_id: ids).destroy_all
      existing = bindings.index_by { |binding| binding.knowledge_base_id.to_s.downcase }
      bases.each { |base| enable_binding!(bindings, existing[base.id.to_s.downcase], base, user_id) }
    end

    def self.enable_binding!(bindings, binding, base, user_id)
      if binding
        binding.update!(enabled: true, updated_by_id: user_id) unless binding.enabled?
      else
        bindings.create!(knowledge_base: base, enabled: true, created_by_id: user_id, updated_by_id: user_id)
      end
    end
    private_class_method :valid_uuid?, :validate_identity!, :canonical_ids!, :locked_profile!, :selected_bases!, :replace_bindings!, :enable_binding!
  end
end
