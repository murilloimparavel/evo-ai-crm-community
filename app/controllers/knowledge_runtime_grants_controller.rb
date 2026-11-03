# frozen_string_literal: true

# Dedicated internal credential; never accept the legacy shared CRM token.
class KnowledgeRuntimeGrantsController < ActionController::API
  def identity
    return head :unauthorized unless authorized_dispatch?

    identity = KnowledgeRuntime::DispatchIdentity.resolve(display_id: params[:display_id], bot_id: params[:bot_id],
                                                          message_ids: params[:message_ids])
    conversation = Conversation.find(identity.conversation_id)
    return head :forbidden if conversation.contact_id.blank?

    response.headers['Cache-Control'] = 'no-store'
    render json: { conversation_id: conversation.id, contact_id: conversation.contact_id }
  rescue KnowledgeRuntime::DispatchIdentity::Denied, ActiveRecord::RecordNotFound
    head :forbidden
  end

  def create
    return head :unauthorized unless authorized_dispatch?

    digest = params[:request_sha256]
    return head :unprocessable_entity unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)

    token = KnowledgeRuntime::GrantIssuer.issue_for_dispatch(display_id: params[:display_id],
                                                             bot_id: params[:bot_id],
                                                             message_ids: params[:message_ids], request_sha256: digest)
    response.headers['Cache-Control'] = 'no-store'
    render json: { grant: token }
  rescue KnowledgeRuntime::GrantIssuer::Denied
    head :forbidden
  end

  private

  def authorized_dispatch?
    secret = ENV.fetch('KNOWLEDGE_RUNTIME_DISPATCH_TOKEN', '')
    supplied = request.headers['X-Knowledge-Dispatch-Token'].to_s
    ENV['KNOWLEDGE_RUNTIME_DISPATCH_ENABLED'] == 'true' && secret.bytesize >= 32 &&
      supplied.bytesize == secret.bytesize && ActiveSupport::SecurityUtils.secure_compare(secret, supplied)
  end
end
