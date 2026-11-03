# frozen_string_literal: true

class KnowledgeRuntimeActionsController < ActionController::API
  def create
    return head :unauthorized unless authorized_processor?
    return head :unprocessable_entity unless request.raw_post.bytesize.between?(1, 8192)

    result = KnowledgeRuntime::Actions.call(token: request.headers['X-Knowledge-Grant'].to_s,
                                            proof_token: request.headers['X-Knowledge-Executor'].to_s, body: request.raw_post)
    response.headers['Cache-Control'] = 'no-store'
    render json: result
  rescue KnowledgeRuntime::Actions::Denied, ActiveRecord::RecordInvalid
    head :forbidden
  end

  private

  def authorized_processor?
    secret = ENV.fetch('KNOWLEDGE_RUNTIME_ACTIONS_TOKEN', '')
    supplied = request.headers['X-Knowledge-Actions-Token'].to_s
    ENV['KNOWLEDGE_RUNTIME_ACTIONS_ENABLED'] == 'true' && secret.bytesize >= 32 &&
      supplied.bytesize == secret.bytesize && ActiveSupport::SecurityUtils.secure_compare(secret, supplied)
  end
end
