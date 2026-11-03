# frozen_string_literal: true

require 'jwt'
require 'openssl'
require 'json'

module KnowledgeRuntime
  # Only incoming customer text up to the dispatch event may cross sessions.
  class CustomerHistory
    class Denied < StandardError; end
    FIELDS = %w[account_scope conversation_id inbox_id contact_id bot_id root_agent_id event_id].freeze

    def self.call(token)
      fetch(token).fetch(:turns)
    end

    def self.fetch(token)
      claims = verified_claims(token)
      event = Message.find_by!(id: claims['event_id'], conversation_id: claims['conversation_id'])
      raise Denied unless visible_message?(event)

      turns = customer_turns!(claims, event)

      # Until provenance is verified, indicate omissions without disclosing text.
      { turns: turns, history_incomplete: omitted_responses?(claims, event) }
    rescue ActiveRecord::RecordNotFound
      raise Denied
    end

    def self.customer_turns!(claims, event)
      # UUIDs do not encode insertion order. Equal timestamps at the boundary
      # cannot establish whether another message occurred before the event.
      reject_ambiguous_boundary!(event)

      messages = Message.where(conversation_id: claims['conversation_id'], inbox_id: claims['inbox_id'],
                               message_type: :incoming, private: false, content_type: :text)
                        .where('created_at < ? OR (created_at = ? AND id <= ?)', event.created_at, event.created_at, event.id)
                        .reorder(created_at: :desc, id: :desc).limit(100).pluck(:content, :created_at, :content_attributes).reverse
                        .select { |row| visible_attributes?(row[2]) }
      raise Denied unless messages.pluck(1).uniq.length == messages.length

      validated_turns!(messages)
    end

    def self.reject_ambiguous_boundary!(event)
      raise Denied if Message.where(conversation_id: event.conversation_id, created_at: event.created_at).where.not(id: event.id).exists?
    end

    def self.validated_turns!(messages)
      turns = messages.map(&:first).select { |text| text.is_a?(String) && text.strip.present? }
      raise Denied if turns.empty? || turns.sum(&:length) > 100_000

      turns
    end

    def self.visible_attributes?(attributes)
      return false unless attributes.nil? || attributes.is_a?(Hash)

      values = attributes || {}
      %w[deleted revoked_by_contact].none? { |field| ActiveModel::Type::Boolean.new.cast(values[field]) }
    end

    def self.visible_message?(message)
      message && visible_attributes?(message.content_attributes)
    end

    def self.omitted_responses?(claims, event)
      Message.where(conversation_id: claims['conversation_id'], inbox_id: claims['inbox_id'],
                    message_type: :outgoing, private: false).exists?(['created_at < ?', event.created_at])
    end

    def self.verified_claims(token)
      raise Denied unless token.is_a?(String) && token.bytesize.between?(1, 8192)

      header = JWT.decode(token, nil, false).last
      raise Denied unless header['alg'] == 'RS256' && header['kid'].is_a?(String)

      options = { algorithm: 'RS256', iss: ENV.fetch('KNOWLEDGE_RUNTIME_GRANT_ISSUER'), verify_iss: true,
                  aud: ENV.fetch('KNOWLEDGE_RUNTIME_GRANT_AUDIENCE'), verify_aud: true,
                  required_claims: %w[iss aud iat exp jti request_sha256] + FIELDS }
      claims = JWT.decode(token, verification_key(header['kid']), true, options).first
      validate_claims!(claims)
      revalidate_claims!(claims, options)
      validate_event!(claims)

      claims
    rescue KeyError, JSON::ParserError, JWT::DecodeError, JWT::VerificationError, JWT::ExpiredSignature, OpenSSL::PKey::PKeyError,
           ActiveRecord::RecordNotFound, GrantIssuer::Denied
      raise Denied
    end

    def self.validate_event!(claims)
      raise Denied unless visible_message?(Message.find_by(id: claims['event_id'], conversation_id: claims['conversation_id']))
    end

    def self.validate_claims!(claims)
      raise Denied unless claims['iat'].is_a?(Integer) && claims['exp'].is_a?(Integer) &&
                          (1..60).cover?(claims['exp'] - claims['iat']) &&
                          claims['request_sha256'].to_s.match?(/\A[0-9a-f]{64}\z/)
    end

    def self.revalidate_claims!(claims, options)
      fresh = GrantIssuer.issue(conversation_id: claims['conversation_id'], message_id: claims['event_id'],
                                bot_id: claims['bot_id'], request_sha256: claims['request_sha256'])
      current_key = OpenSSL::PKey::RSA.new(ENV.fetch('KNOWLEDGE_RUNTIME_GRANT_PRIVATE_KEY')).public_key
      current = JWT.decode(fresh, current_key, true, options).first
      raise Denied unless FIELDS.all? { |field| claims[field] == current[field] }
    end

    # Optional JSON map of trusted key IDs to PEM-encoded public keys permits
    # overlap during rotation. Never take a key or URL from the JWT itself.
    def self.verification_key(kid)
      current_kid = ENV.fetch('KNOWLEDGE_RUNTIME_GRANT_KID')
      if kid == current_kid
        key = OpenSSL::PKey::RSA.new(ENV.fetch('KNOWLEDGE_RUNTIME_GRANT_PRIVATE_KEY')).public_key
      else
        keys = JSON.parse(ENV.fetch('KNOWLEDGE_RUNTIME_HISTORY_PUBLIC_KEYS', '{}'))
        raise Denied unless keys.is_a?(Hash) && keys.length <= 10 && keys[kid].is_a?(String)

        key = OpenSSL::PKey::RSA.new(keys[kid])
        raise Denied if key.private?
      end
      raise Denied unless key.n.num_bits >= 2048

      key
    end
    private_class_method :verification_key, :customer_turns!, :reject_ambiguous_boundary!, :validated_turns!,
                         :omitted_responses?, :validate_event!, :validate_claims!, :revalidate_claims!
  end
end
