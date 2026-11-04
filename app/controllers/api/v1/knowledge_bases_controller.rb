class Api::V1::KnowledgeBasesController < Api::V1::BaseController
  require_permissions({ index: 'ai_knowledge.read', show: 'ai_knowledge.read', create: 'ai_knowledge.create',
                        update: 'ai_knowledge.update', archive: 'ai_knowledge.publish', test_retrieval: 'ai_knowledge.read' })
  before_action :ensure_user!
  before_action :find_base!, only: %i[show update archive test_retrieval]

  def index
    render json: { data: scope.order(:name).map { |base| representation(base) } }
  end

  def show
    render json: { data: representation(@base) }
  end

  def create
    base = nil
    KnowledgeBase.transaction do
      ensure_default_base!
      base = scope.new(base_params.except(:lock_version))
      base.created_by_id = Current.user.id
      base.updated_by_id = Current.user.id
      base.save!
    end
    render json: { data: representation(base) }, status: :created
  end

  def update
    return render json: { error: 'revision_required' }, status: :conflict if params.dig(:knowledge_base, :lock_version).blank?

    @base.assign_attributes(base_params)
    @base.updated_by_id = Current.user.id
    @base.save!
    render json: { data: representation(@base) }
  rescue ActiveRecord::StaleObjectError
    render json: { error: 'revision_conflict' }, status: :conflict
  end

  def test_retrieval
    return render json: { error: 'base_archived' }, status: :unprocessable_entity unless @base.status == 'active'

    query = params[:query].to_s.strip.first(500)
    return render json: { data: [] } if query.blank?

    entries = KnowledgeEntry.search_published(query, limit: 5).where(account_scope: current_scope, knowledge_base_id: @base.id)
    render json: { data: entries.map { |entry| { id: entry.id, title: entry.title, excerpt: entry.body.first(2000), source: entry.source } } }
  end

  def archive
    return render json: { error: 'Forbidden' }, status: :forbidden unless Current.user.administrator?
    return render json: { error: 'legacy_default_required' }, status: :unprocessable_entity if @base.legacy_default?
    return render json: { error: 'revision_required' }, status: :conflict if params[:lock_version].blank?

    @base.lock_version = params[:lock_version]
    @base.update!(status: 'archived', updated_by_id: Current.user.id)
    render json: { data: representation(@base) }
  rescue ActiveRecord::StaleObjectError
    render json: { error: 'revision_conflict' }, status: :conflict
  end

  private

  def ensure_user!
    render json: { error: 'Forbidden' }, status: :forbidden unless Current.user.is_a?(User) && !service_authenticated?
  end

  def current_scope
    (EvoExtensionPoints::RuntimeContext.current_scope_id.presence || RuntimeConfig.account&.dig('id').presence || 'community').to_s
  end

  def scope
    KnowledgeBase.where(account_scope: current_scope)
  end

  def ensure_default_base!
    defaults = scope.where(legacy_default: true)
    defaults.first || KnowledgeBase.create_or_find_by!(account_scope: current_scope, legacy_default: true) { |base| base.name = 'Geral' }
  rescue ActiveRecord::RecordInvalid
    defaults.first || raise
  end

  def find_base!
    @base = scope.find(params[:id])
  end

  def base_params
    params.require(:knowledge_base).permit(:name, :description, :lock_version)
  end

  def representation(base)
    base.attributes.slice('id', 'name', 'description', 'status', 'legacy_default', 'lock_version', 'created_at', 'updated_at').merge(
      'entries_count' => base.knowledge_entries.count, 'published_count' => base.knowledge_entries.published.count,
      'can_archive' => Current.user&.administrator? && !base.legacy_default? && base.status == 'active',
      'can_publish_entries' => Current.user&.administrator? && base.legacy_default? && base.status == 'active'
    )
  end
end
