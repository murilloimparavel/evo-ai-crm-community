class Api::V1::KnowledgeEntriesController < Api::V1::BaseController
  require_permissions({ index: 'ai_knowledge.read', show: 'ai_knowledge.read',
                        create: 'ai_knowledge.create', update: 'ai_knowledge.update',
                        destroy: 'ai_knowledge.delete', publish: 'ai_knowledge.publish',
                        archive: 'ai_knowledge.publish', search: 'ai_knowledge.read' })

  before_action :load_entry, only: %i[show update destroy publish archive]
  before_action :ensure_user!, except: [:search]

  # Keep the existing account-scoped list and category filters.
  def index # rubocop:disable Metrics/AbcSize
    entries = scoped_entries.order(updated_at: :desc)
    entries = entries.where(knowledge_base_id: params[:knowledge_base_id]) if params[:knowledge_base_id].present?
    entries = entries.where(status: params[:status]) if KnowledgeEntry::STATUSES.include?(params[:status])
    entries = entries.where(content_type: params[:content_type]) if KnowledgeEntry::CONTENT_TYPES.include?(params[:content_type])
    if params[:q].present?
      entries = entries.where('title ILIKE :q OR body ILIKE :q', q: "%#{KnowledgeEntry.sanitize_sql_like(params[:q].to_s.first(200))}%")
    end
    total = entries.count
    render json: { data: entries.limit(100).map { |entry| entry_data(entry) }, meta: { total_count: total } }
  end

  def show
    render json: { data: entry_data(@entry) }
  end

  # Keep scope and publication checks together at the write boundary.
  def create # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
    entry = scoped_entries.new(entry_params.except(:status))
    entry.knowledge_base ||= default_base if entry_params[:knowledge_base_id].blank?
    return forbidden unless entry.knowledge_base && entry.knowledge_base.account_scope == current_scope && entry.knowledge_base.status == 'active'

    entry.status = 'draft'
    entry.created_by_id = Current.user&.id
    entry.updated_by_id = Current.user&.id
    entry.save!
    render json: { data: entry_data(entry) }, status: :created
  end

  # Lock the article and destination before applying the combined final state.
  def update # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
    @entry.with_lock do
      next forbidden unless editable?(@entry)

      attributes = entry_params
      next forbidden if attributes.key?(:knowledge_base_id) && attributes[:knowledge_base_id].blank?

      target_id = attributes[:knowledge_base_id].presence || @entry.knowledge_base_id
      target = KnowledgeBase.lock.find_by(id: target_id, account_scope: current_scope, status: 'active')
      next forbidden unless target

      requested_status = attributes[:status].presence || @entry.status
      next forbidden if requested_status == 'published' && !target.legacy_default?

      if requested_status != @entry.status
        next forbidden unless administrator? && KnowledgeEntry::STATUSES.include?(requested_status) &&
                              has_user_permission?(Current.user.id, 'ai_knowledge.publish')

        @entry.published_at = Time.current if requested_status == 'published'
        @entry.published_at = nil if requested_status == 'draft'
      end
      @entry.assign_attributes(attributes)
      @entry.updated_by_id = Current.user&.id
      @entry.save!
    end
    return if performed?

    render json: { data: entry_data(@entry) }
  end

  def publish
    @entry.with_lock do
      target = KnowledgeBase.lock.find_by(id: @entry.knowledge_base_id, account_scope: current_scope, status: 'active')
      next forbidden unless administrator? && target&.legacy_default?

      @entry.update!(status: 'published', published_at: Time.current, updated_by_id: Current.user&.id)
    end
    return if performed?

    render json: { data: entry_data(@entry) }
  end

  def archive
    return forbidden unless administrator?

    @entry.update!(status: 'archived', updated_by_id: Current.user&.id)
    render json: { data: entry_data(@entry) }
  end

  def destroy
    return forbidden unless administrator?

    @entry.destroy!
    head :no_content
  end

  # Validate identity and filter the legacy base before applying result limits.
  def search # rubocop:disable Metrics/AbcSize
    return render json: { error: 'conversation_id required' }, status: :bad_request if params[:conversation_id].blank?
    return render json: { error: 'conversation not found' }, status: :not_found unless Conversation.exists?(id: params[:conversation_id])

    query = params[:q].to_s.strip.first(500)
    return render json: { data: [], meta: { total_count: 0 } } if query.blank?

    entries = KnowledgeEntry.search_published(query, limit: params[:limit] || 5)
                            .joins(:knowledge_base)
                            .where(account_scope: current_scope, knowledge_bases: {
                                     account_scope: current_scope, legacy_default: true, status: 'active'
                                   })
    render json: { data: entries.map { |entry| entry_data(entry) }, meta: { total_count: entries.length } }
  end

  private

  def current_scope
    (EvoExtensionPoints::RuntimeContext.current_scope_id.presence || RuntimeConfig.account&.dig('id').presence || 'community').to_s
  end

  def default_base
    scope = KnowledgeBase.where(account_scope: current_scope, legacy_default: true)
    scope.first || KnowledgeBase.create_or_find_by!(account_scope: current_scope, legacy_default: true) { |base| base.name = 'Geral' }
  rescue ActiveRecord::RecordInvalid
    scope.first || raise
  end

  def scoped_entries
    KnowledgeEntry.where(account_scope: current_scope)
  end

  def load_entry
    @entry = scoped_entries.find(params[:id])
  end

  def administrator?
    Current.user&.administrator?
  end

  def ensure_user!
    forbidden if Current.user.blank?
  end

  def editable?(entry)
    administrator? || (entry.status == 'draft' && entry.created_by_id == Current.user&.id)
  end

  def forbidden
    render json: { error: 'Forbidden' }, status: :forbidden
  end

  def entry_params
    (params[:ai_knowledge_entry] || params.require(:knowledge_entry)).permit(:title, :body, :content_type, :source, :status, :knowledge_base_id,
                                                                             tags: [])
  end

  def entry_data(entry)
    can_manage_publication = administrator? && has_user_permission?(Current.user.id, 'ai_knowledge.publish')
    entry.attributes.slice('id', 'title', 'body', 'content_type', 'tags', 'source', 'status',
                           'created_at', 'updated_at', 'published_at', 'created_by_id', 'updated_by_id', 'knowledge_base_id')
         .merge('can_edit' => editable?(entry),
                'can_publish' => !!(can_manage_publication && entry.knowledge_base&.legacy_default? && entry.knowledge_base&.status == 'active'),
                'can_archive' => !!can_manage_publication)
  end
end
