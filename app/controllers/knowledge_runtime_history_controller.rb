# frozen_string_literal: true

# Internal endpoint; requires both a dedicated processor credential and an
# unexpired CRM-issued dispatch grant. Never include private or agent messages.
class KnowledgeRuntimeHistoryController < ActionController::API
  def create
    return head :unauthorized unless authorized_processor?

    history = KnowledgeRuntime::CustomerHistory.fetch(request.headers['X-Knowledge-Grant'].to_s)
    history = KnowledgeRuntime::ProvenanceHistory.enrich(history, token: request.headers['X-Knowledge-Grant'].to_s,
                                                                  executor_token: request.headers['X-Knowledge-Executor'].to_s)
    response.headers['Cache-Control'] = 'no-store'
    render json: history
  rescue KnowledgeRuntime::CustomerHistory::Denied
    head :forbidden
  end

  private

  def authorized_processor?
    secret = ENV.fetch('KNOWLEDGE_RUNTIME_HISTORY_TOKEN', '')
    supplied = request.headers['X-Knowledge-History-Token'].to_s
    ENV['KNOWLEDGE_RUNTIME_HISTORY_ENABLED'] == 'true' && secret.bytesize >= 32 &&
      supplied.bytesize == secret.bytesize && ActiveSupport::SecurityUtils.secure_compare(secret, supplied)
  end
end
