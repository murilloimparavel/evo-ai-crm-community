# frozen_string_literal: true

require 'jwt'
require 'openssl'
require 'digest'

module KnowledgeRuntime
  class ActionProof
    class Denied < StandardError; end
    FIELDS = %w[account_scope conversation_id inbox_id contact_id bot_id root_agent_id event_id].freeze

    def self.verify!(token:, grant:, body:)
      raise Denied unless token.is_a?(String) && token.bytesize.between?(1, 8192)

      claims = decode!(token)
      validate_context!(claims, grant, body)
      validate_expiry!(claims, grant)
      claims
    rescue JWT::DecodeError, KeyError, OpenSSL::PKey::PKeyError
      raise Denied
    end

    def self.decode!(token)
      key = OpenSSL::PKey::RSA.new(ENV.fetch('KNOWLEDGE_EXECUTOR_PUBLIC_KEY'))
      raise Denied if key.private? || key.n.num_bits < 2048

      JWT.decode(token, key, true, algorithm: 'RS256', iss: ENV.fetch('KNOWLEDGE_EXECUTOR_ISSUER'), verify_iss: true,
                                   aud: 'knowledge-action', verify_aud: true,
                                   required_claims: %w[iss aud iat exp agent_id action_id body_sha256] + FIELDS).first
    end

    def self.validate_context!(claims, grant, body)
      raise Denied unless FIELDS.all? { |field| claims[field] == grant[field] }
      raise Denied unless claims['body_sha256'] == Digest::SHA256.hexdigest(body)
      raise Denied unless %w[agent_id action_id].all? { |field| claims[field].to_s.match?(BindingSet::UUID) }
    end

    def self.validate_expiry!(claims, grant)
      raise Denied unless claims['iat'].is_a?(Integer) && claims['exp'].is_a?(Integer)
      raise Denied unless (1..30).cover?(claims['exp'] - claims['iat']) && claims['exp'] <= grant['exp'] && claims['iat'] <= Time.now.to_i
    end
    private_class_method :decode!, :validate_context!, :validate_expiry!
  end
end
