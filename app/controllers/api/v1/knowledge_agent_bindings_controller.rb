class Api::V1::KnowledgeAgentBindingsController < Api::V1::BaseController
  require_permissions({ show: 'ai_knowledge.read', update: 'ai_knowledge.update' })
  before_action :authorize_actor!
  before_action :verify_agent!

  def show
    profile = KnowledgeAgentAccessProfile.find_by(account_scope: current_scope, external_agent_id: agent_id)
    ids = KnowledgeAgentBinding.joins(:knowledge_base).where(account_scope: current_scope, external_agent_id: agent_id, enabled: true,
                                                             knowledge_bases: { status: 'active', account_scope: current_scope })
                               .pluck(:knowledge_base_id)
    render json: { data: { revision: profile&.revision || 0, base_ids: ids } }
  end

  def update
    revision = KnowledgeRuntime::BindingSet.replace!(account_scope: current_scope, agent_id: agent_id,
                                                     base_ids: params[:base_ids], expected_revision: params[:expected_revision],
                                                     user_id: Current.user.id)
    render json: { data: { revision: revision } }
  rescue KnowledgeRuntime::BindingSet::RevisionConflict
    render json: { error: 'revision_conflict' }, status: :conflict
  rescue KnowledgeRuntime::BindingSet::InvalidSelection
    render json: { error: 'invalid_selection' }, status: :unprocessable_entity
  end

  private

  def authorize_actor!
    permission = action_name == 'show' ? 'ai_agents.read' : 'ai_agents.update'
    return if Current.user.is_a?(User) && !service_authenticated? && has_user_permission?(Current.user.id, permission)

    render json: { error: 'Forbidden' }, status: :forbidden
  end

  def verify_agent!
    KnowledgeRuntime::CommunityAgentAuthority.verify!(account_scope: current_scope, agent_id: agent_id, request_headers: request.headers)
  rescue KnowledgeRuntime::CommunityAgentAuthority::Unavailable
    render json: { error: 'agent_scope_unavailable' }, status: :service_unavailable
  rescue KnowledgeRuntime::CommunityAgentAuthority::UnknownAgent
    render json: { error: 'agent_not_found' }, status: :not_found
  end

  def current_scope
    (EvoExtensionPoints::RuntimeContext.current_scope_id.presence || RuntimeConfig.account&.dig('id').presence || 'community').to_s
  end

  def agent_id
    params[:agent_id].to_s.downcase
  end
end
