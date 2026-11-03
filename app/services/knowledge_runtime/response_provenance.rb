# frozen_string_literal: true

require 'jwt'
require 'openssl'
require 'digest'

module KnowledgeRuntime
  # Only authenticated postbacks use this ledger. JWTs are never persisted.
  class ResponseProvenance
    class Denied < StandardError; end
    CATEGORIES = %w[search_crm_knowledge manage_conversation_labels pipeline_manipulation transfer_to_human external_live_read].freeze
    IDENTITY_FIELDS = %w[conversation_id bot_id account_scope inbox_id contact_id root_agent_id event_id].freeze
    ATTRIBUTES = %w[config_sha256 body_sha256 profile_revision sources tool_categories].freeze

    def self.decode(token, audience, allow_expired: false)
      claims = signed_claims!(token, audience, allow_expired)
      validate_lifetime!(claims)
      validate_executor!(claims)
      grant = grant_identity!(claims, audience, allow_expired)
      [claims, grant]
    rescue JWT::DecodeError, KeyError, OpenSSL::PKey::PKeyError, CustomerHistory::Denied
      raise Denied
    end

    def self.signed_claims!(token, audience, allow_expired)
      raise Denied unless token.is_a?(String) && token.bytesize.between?(1, 32_768)

      key = OpenSSL::PKey::RSA.new(ENV.fetch('KNOWLEDGE_EXECUTOR_PUBLIC_KEY'))
      raise Denied if key.private? || key.n.num_bits < 2048

      options = { algorithm: 'RS256', iss: ENV.fetch('KNOWLEDGE_EXECUTOR_ISSUER'), verify_iss: true,
                  aud: audience, verify_aud: true, verify_expiration: !allow_expired,
                  required_claims: %w[iss aud iat exp agent_id config_sha256] }
      JWT.decode(token, key, true, options).first
    end

    def self.grant_identity!(claims, audience, allow_expired)
      return CustomerHistory.verified_claims(claims.fetch('grant')) unless audience == 'knowledge-response'
      return signed_delivery_identity!(claims) if allow_expired

      token = GrantIssuer.issue(conversation_id: claims['conversation_id'], message_id: claims['event_id'],
                                bot_id: claims['bot_id'], request_sha256: claims['request_sha256'])
      current = CustomerHistory.verified_claims(token)
      raise Denied unless IDENTITY_FIELDS.all? { |field| current[field] == claims[field] }

      current
    rescue GrantIssuer::Denied
      raise Denied
    end

    def self.validate_lifetime!(claims)
      raise Denied unless claims['iat'].is_a?(Integer) && claims['exp'].is_a?(Integer)
      raise Denied unless (0..86_400).cover?(Time.now.to_i - claims['iat']) && (1..60).cover?(claims['exp'] - claims['iat'])
    end

    def self.validate_executor!(claims)
      raise Denied unless claims['agent_id'].to_s.match?(BindingSet::UUID) && claims['config_sha256'].to_s.match?(/\A[0-9a-f]{64}\z/)
    end

    def self.signed_delivery_identity!(claims)
      raise Denied unless %w[conversation_id bot_id].all? { |field| claims[field].to_s.match?(BindingSet::UUID) }
      raise Denied unless claims['account_scope'].is_a?(String)

      claims.slice(*IDENTITY_FIELDS)
    end

    def self.record!(token:, content:, conversation:, bot:)
      proof, grant = decode(token, 'knowledge-response', allow_expired: true)
      validate_delivery!(proof, grant, content, conversation, bot)
      reusable = proof.fetch('reusable', true) && fresh_authority?(token, grant)
      lock_key = Digest::SHA256.hexdigest(proof['jti'])[0, 16].to_i(16) % ((2**63) - 1)
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{lock_key})")
        existing = KnowledgeResponseProvenance.find_by(proof_jti: proof['jti'])
        next existing_message!(existing, conversation, proof) if existing

        message = yield
        next nil unless message

        persist!(message, proof, grant, content, reusable)
      end
    end

    def self.fresh_authority?(token, grant)
      _, verified = decode(token, 'knowledge-response')
      IDENTITY_FIELDS.all? { |field| verified[field] == grant[field] }
    rescue Denied
      false
    end

    def self.validate_delivery!(proof, grant, content, conversation, bot)
      raise Denied unless grant['conversation_id'] == conversation.id.to_s && grant['bot_id'] == bot.id.to_s
      raise Denied unless proof['body_sha256'] == Digest::SHA256.hexdigest(content) && proof['jti'].to_s.match?(BindingSet::UUID)

      validate_sources!(proof)
    end

    def self.validate_reuse!(proof)
      raise Denied if proof.key?('reusable') && [true, false].exclude?(proof['reusable'])
      raise Denied if proof['tool_categories'].is_a?(Array) && proof['tool_categories'].include?('external_live_read') && proof['reusable'] != false
    end

    def self.validate_sources!(proof)
      validate_reuse!(proof)
      raise Denied unless proof['tool_categories'].is_a?(Array) && (proof['tool_categories'] - CATEGORIES).empty?
      raise Denied unless proof['sources'].is_a?(Array) && proof['sources'].length <= 100 && proof['profile_revision'].is_a?(Integer)
    end

    def self.existing_message!(existing, conversation, proof)
      message = existing.message
      raise Denied unless message && message.conversation_id == conversation.id && existing.body_sha256 == proof['body_sha256']

      message
    end

    def self.persist!(message, proof, grant, content, reusable)
      raise Denied unless message.content == content && message.outgoing? && !message.private?

      attributes = proof.slice(*ATTRIBUTES).merge(reusable: reusable, message: message,

                                                  proof_jti: proof['jti'], account_scope: grant['account_scope'], executor_id: proof['agent_id'])
      KnowledgeResponseProvenance.create!(attributes)
      message
    end

    # Called only inside ProvenanceHistory's repeatable-read snapshot.
    def self.reusable?(record, grant, executor)
      return false unless record.reusable? && current_policy?(record, grant, executor) && current_message?(record)
      return false unless current_revision(record) == record.profile_revision

      record.sources.all? { |source| current_source?(record, source) }
    end

    def self.current_policy?(record, grant, executor)
      executor['tool_categories'].is_a?(Array) && (record.tool_categories - executor['tool_categories']).empty? &&
        record.account_scope == grant['account_scope'] && record.executor_id == executor['agent_id'] &&
        record.config_sha256 == executor['config_sha256']
    end

    def self.current_message?(record)
      message = record.message
      CustomerHistory.visible_message?(message) && %w[delivered read].include?(message.status) && message.content.is_a?(String) &&
        Digest::SHA256.hexdigest(message.content) == record.body_sha256
    end

    def self.current_revision(record)
      KnowledgeAgentAccessProfile.find_by(account_scope: record.account_scope, external_agent_id: record.executor_id)&.revision || 0
    end

    def self.current_source?(record, source)
      return false unless source.is_a?(Hash)

      entry = source_entry(record, source['id'])
      entry && entry.knowledge_base.lock_version == source['base_version'] &&
        Digest::SHA256.hexdigest(entry.body) == source['body_sha256'] && entry.updated_at.iso8601(6) == source['updated_at']
    end

    def self.source_entry(record, id)
      KnowledgeEntry.joins(knowledge_base: :knowledge_agent_bindings)
                    .where(id: id, account_scope: record.account_scope, status: 'published',
                           knowledge_bases: { account_scope: record.account_scope, status: 'active' },
                           knowledge_agent_bindings: { account_scope: record.account_scope,
                                                       external_agent_id: record.executor_id, enabled: true }).first
    end
    private_class_method :signed_claims!, :grant_identity!, :validate_lifetime!, :validate_executor!, :signed_delivery_identity!, :fresh_authority?,
                         :validate_delivery!, :validate_reuse!, :validate_sources!, :existing_message!, :persist!, :current_policy?,
                         :current_message?, :current_revision, :current_source?, :source_entry
  end
end
