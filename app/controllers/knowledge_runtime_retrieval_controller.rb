# frozen_string_literal: true

require 'digest'
require 'jwt'
require 'openssl'

# This endpoint trusts only a dedicated processor holding the executor signing
# key. The processor must revalidate delegation before issuing every proof.
class KnowledgeRuntimeRetrievalController < ActionController::API
  def create
    return head :unauthorized unless authorized_processor?

    grant = KnowledgeRuntime::CustomerHistory.verified_claims(request.headers['X-Knowledge-Grant'].to_s)
    proof = verify_executor_proof!(grant)
    payload = parse_payload!

    revision = KnowledgeAgentAccessProfile.find_by(account_scope: grant.fetch('account_scope'),
                                                   external_agent_id: proof.fetch('agent_id'))&.revision || 0
    results = KnowledgeRuntime::Retrieval.call(account_scope: grant.fetch('account_scope'), agent_id: proof.fetch('agent_id'),
                                               query: payload['query'], limit: payload.fetch('limit', 5))
    response.headers['Cache-Control'] = 'no-store'
    render json: { results: results, profile_revision: revision }
  rescue KnowledgeRuntime::CustomerHistory::Denied, KnowledgeRuntime::Retrieval::InvalidRequest,
         JWT::DecodeError, OpenSSL::PKey::PKeyError, KeyError, JSON::ParserError, ArgumentError
    head :forbidden
  end

  private

  def parse_payload!
    payload = JSON.parse(request.raw_post)
    raise KnowledgeRuntime::Retrieval::InvalidRequest unless payload.is_a?(Hash) && (payload.keys - %w[query limit]).empty?

    payload
  end

  def authorized_processor?
    secret = ENV.fetch('KNOWLEDGE_RUNTIME_RETRIEVAL_TOKEN', '')
    supplied = request.headers['X-Knowledge-Retrieval-Token'].to_s
    ENV['KNOWLEDGE_RUNTIME_RETRIEVAL_ENABLED'] == 'true' && secret.bytesize >= 32 &&
      supplied.bytesize == secret.bytesize && ActiveSupport::SecurityUtils.secure_compare(secret, supplied)
  end

  def verify_executor_proof!(grant)
    key = OpenSSL::PKey::RSA.new(ENV.fetch('KNOWLEDGE_EXECUTOR_PUBLIC_KEY'))
    raise ArgumentError unless !key.private? && key.n.num_bits >= 2048

    options = { algorithm: 'RS256', iss: ENV.fetch('KNOWLEDGE_EXECUTOR_ISSUER'), verify_iss: true,
                aud: 'knowledge-retrieval', verify_aud: true,
                required_claims: %w[iss aud iat exp account_scope conversation_id root_agent_id event_id agent_id body_sha256] }
    proof = JWT.decode(request.headers['X-Knowledge-Executor'].to_s, key, true, options).first
    validate_proof_expiry!(proof, grant)
    raise ArgumentError unless %w[account_scope conversation_id root_agent_id event_id].all? { |name| proof[name] == grant[name] }
    raise ArgumentError unless proof['body_sha256'] == Digest::SHA256.hexdigest(request.raw_post)

    proof
  end

  def validate_proof_expiry!(proof, grant)
    raise ArgumentError unless proof['iat'].is_a?(Integer) && proof['exp'].is_a?(Integer) &&
                               (1..30).cover?(proof['exp'] - proof['iat']) && proof['exp'] <= grant['exp']
  end
end
