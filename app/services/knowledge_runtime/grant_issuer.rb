# frozen_string_literal: true

require 'jwt'
require 'openssl'
require 'securerandom'
require 'uri'

module KnowledgeRuntime
  # Not connected to delivery: a grant must never be logged, persisted in a job
  # argument, included in model-visible history, or treated as retrieval authority
  # without independent session, delegation and current-binding verification.
  # The explicit community scope is not proof of agent ownership or caller
  # authorization. This does not check agent existence, session, delegation,
  # event freshness or replay; never use the grant alone to authorize retrieval.
  class GrantIssuer
    class Denied < StandardError; end
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    TTL = 60
    EVENT_MAX_AGE = 300

    # Only an authenticated internal transport may call this entry point. The
    # canonical conversation UUID is resolved from the database, not metadata.
    # This alone does not prevent reissuance, authenticate a session, prove
    # tenant/delegation or authorize retrieval; keep disconnected until those
    # controls and the one-use consumption protocol are implemented.
    def self.issue_for_dispatch(display_id:, message_ids:, bot_id:, request_sha256: nil)
      identity = DispatchIdentity.resolve(display_id: display_id, message_ids: message_ids, bot_id: bot_id)
      issue(conversation_id: identity.conversation_id, message_id: identity.message_ids.last, bot_id: identity.bot_id,
            request_sha256: request_sha256)
    rescue DispatchIdentity::Denied
      raise Denied, 'grant_denied'
    end

    def self.issue(conversation_id:, message_id:, bot_id:, request_sha256: nil)
      validate_request!(conversation_id, message_id, bot_id, request_sha256)
      issuer, audience, kid, pem = signing_configuration!
      conversation, message, bot = verified_records!(conversation_id, message_id, bot_id)
      root = strict_root_agent_id(bot)
      key = OpenSSL::PKey::RSA.new(pem)
      raise Denied, 'grant_denied' unless key.private? && key.n.num_bits >= 2048

      claims = build_claims([issuer, audience], [conversation, message, bot], root)
      claims[:request_sha256] = request_sha256 if request_sha256
      JWT.encode(claims, key, 'RS256', { kid: kid, typ: 'JWT' })
    rescue OpenSSL::OpenSSLError, URI::InvalidURIError, JWT::EncodeError
      raise Denied, 'grant_denied'
    end

    def self.build_claims(issuance, records, root)
      issuer, audience = issuance
      conversation, message, bot = records
      now = Time.now.to_i
      { iss: issuer, aud: audience, iat: now, exp: now + TTL, jti: SecureRandom.uuid,
        account_scope: community_account_scope!, conversation_id: conversation.id.to_s, inbox_id: conversation.inbox_id.to_s,
        contact_id: conversation.contact_id.to_s,
        bot_id: bot.id.to_s, root_agent_id: root, event_id: message.id.to_s }
    end

    def self.validate_request!(conversation_id, message_id, bot_id, request_sha256)
      raise Denied, 'grant_denied' unless ENV['KNOWLEDGE_RUNTIME_GRANTS_ENABLED'] == 'true'
      raise Denied, 'grant_denied' if request_sha256 && (!request_sha256.is_a?(String) || !request_sha256.match?(/\A[0-9a-f]{64}\z/))
      raise Denied, 'grant_denied' unless [conversation_id, message_id, bot_id].all? { |id| UUID.match?(id.to_s) }
    end

    def self.signing_configuration!
      issuer = ENV.fetch('KNOWLEDGE_RUNTIME_GRANT_ISSUER', nil)
      audience = ENV.fetch('KNOWLEDGE_RUNTIME_GRANT_AUDIENCE', nil)
      kid = ENV.fetch('KNOWLEDGE_RUNTIME_GRANT_KID', nil)
      pem = ENV.fetch('KNOWLEDGE_RUNTIME_GRANT_PRIVATE_KEY', nil)
      raise Denied, 'grant_denied' if [issuer, audience, kid, pem].any?(&:blank?)

      [issuer, audience, kid, pem]
    end

    def self.verified_records!(conversation_id, message_id, bot_id)
      conversation = Conversation.find_by(id: conversation_id)
      raise Denied, 'grant_denied' unless conversation && UUID.match?(conversation.contact_id.to_s)

      message = verified_message!(conversation, message_id)
      bot = verified_bot!(conversation, bot_id)
      [conversation, message, bot]
    end

    def self.verified_message!(conversation, message_id)
      message = Message.find_by(id: message_id, conversation_id: conversation.id, inbox_id: conversation.inbox_id)
      raise Denied, 'grant_denied' unless message&.incoming? && !message.private?

      created_at = message.created_at
      raise Denied, 'grant_denied' unless created_at && created_at <= Time.current && created_at >= EVENT_MAX_AGE.seconds.ago

      message
    end

    def self.verified_bot!(conversation, bot_id)
      assignments = AgentBotInbox.where(inbox_id: conversation.inbox_id, status: :active).limit(2).to_a
      raise Denied, 'grant_denied' unless assignments.one? && assignments.first.agent_bot_id.to_s == bot_id.to_s

      bot = AgentBot.find_by(id: bot_id)
      raise Denied, 'grant_denied' unless bot

      bot
    end
    private_class_method :build_claims, :validate_request!, :signing_configuration!, :verified_records!, :verified_message!, :verified_bot!

    # This contract is deliberately limited to an explicitly configured,
    # single-account Community installation. An extension overriding either
    # runtime context hook may supply per-request tenant context, for which
    # RuntimeConfig.account is not proof of ownership; fail closed instead.
    def self.community_account_scope!
      raise Denied, 'grant_denied' unless ENV['KNOWLEDGE_RUNTIME_ACCOUNT_MODE'] == 'community-single'
      raise Denied, 'grant_denied' if EvoExtensionPoints.impl_for(:runtime_context_current_id) ||
                                      EvoExtensionPoints.impl_for(:runtime_context_with_scope)

      configured = ENV.fetch('KNOWLEDGE_RUNTIME_ACCOUNT_SCOPE', nil)
      scope = local_account_scope!
      raise Denied, 'grant_denied' unless valid_scope?(configured, scope)

      scope
    rescue JSON::ParserError
      raise Denied, 'grant_denied'
    end

    def self.local_account_scope!
      account = RuntimeConfig.account
      raise Denied, 'grant_denied' unless account.nil? || account.is_a?(Hash)

      account_id = account && account['id']
      account_id.nil? || account_id.to_s.empty? ? 'community' : account_id.to_s
    end

    def self.valid_scope?(configured, scope)
      configured.is_a?(String) && configured.match?(/\A[a-zA-Z0-9_-]{1,128}\z/) && configured == scope
    end
    private_class_method :community_account_scope!, :local_account_scope!, :valid_scope?

    def self.strict_root_agent_id(bot)
      uri = URI.parse(bot.outgoing_url.to_s)
      root = root_from_uri!(uri)
      validate_root_config!(bot, root)
      root
    end

    def self.root_from_uri!(uri)
      match = uri.path.match(%r{\A/api/v1/a2a/([0-9a-f-]+)\z})
      root = match && match[1]
      raise Denied, 'grant_denied' unless %w[https http].include?(uri.scheme) && uri.host
      raise Denied, 'grant_denied' unless root && UUID.match?(root)
      raise Denied, 'grant_denied' if uri_extras?(uri)

      root
    end

    def self.uri_extras?(uri)
      uri.userinfo || uri.query || uri.fragment
    end

    def self.validate_root_config!(bot, root)
      config = bot.bot_config
      raise Denied, 'grant_denied' unless config.is_a?(Hash)

      configured = config['agent_id']
      raise Denied, 'grant_denied' if configured && configured != root

      resolved = AgentBots::SessionSyncAgentResolver.new(bot).call
      raise Denied, 'grant_denied' unless resolved == root
    end
    private_class_method :strict_root_agent_id, :root_from_uri!, :uri_extras?, :validate_root_config!
  end
end
