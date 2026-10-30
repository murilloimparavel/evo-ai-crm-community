class Api::V1::KnowledgeEntriesController < Api::V1::BaseController
  require_permissions({ index: 'ai_knowledge.read', show: 'ai_knowledge.read',
                        create: 'ai_knowledge.create', update: 'ai_knowledge.update',
                        destroy: 'ai_knowledge.delete', publish: 'ai_knowledge.publish',
                        archive: 'ai_knowledge.publish', search: 'ai_knowledge.read' })

  before_action :load_entry, only: %i[show update destroy publish archive]
  before_action :ensure_user!, except: [:search]

  # Existing production135c333 method retained without changing knowledge authorization or query behavior.
  def index # rubocop:disable Metrics/AbcSize
    entries = scoped_entries.order(updated_at: :desc)
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

  def create
    entry = scoped_entries.new(entry_params.except(:status))
    entry.status = 'draft'
    entry.created_by_id = Current.user&.id
    entry.updated_by_id = Current.user&.id
    entry.save!
    render json: { data: entry_data(entry) }, status: :created
  end

  # Existing production135c333 method retained without changing knowledge authorization or query behavior.
  def update # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    return forbidden unless editable?(@entry)

    requested_status = entry_params[:status]
    if requested_status.present? && requested_status != @entry.status
      return forbidden unless administrator? && KnowledgeEntry::STATUSES.include?(requested_status)

      @entry.published_at = Time.current if requested_status == 'published'
      @entry.published_at = nil if requested_status == 'draft'
    end
    @entry.assign_attributes(entry_params)
    @entry.updated_by_id = Current.user&.id
    @entry.save!
    render json: { data: entry_data(@entry) }
  end

  def publish
    return forbidden unless administrator?

    @entry.update!(status: 'published', published_at: Time.current, updated_by_id: Current.user&.id)
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

  def search
    return render json: { error: 'conversation_id required' }, status: :bad_request if params[:conversation_id].blank?
    return render json: { error: 'conversation not found' }, status: :not_found unless Conversation.exists?(id: params[:conversation_id])

    query = params[:q].to_s.strip.first(500)
    return render json: { data: [], meta: { total_count: 0 } } if query.blank?

    entries = KnowledgeEntry.search_published(query, limit: params[:limit] || 5).where(account_scope: current_scope)
    render json: { data: entries.map { |entry| entry_data(entry) }, meta: { total_count: entries.length } }
  end

  private

  def current_scope
    (EvoExtensionPoints::RuntimeContext.current_scope_id.presence || RuntimeConfig.account&.dig('id').presence || 'community').to_s
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
    (params[:ai_knowledge_entry] || params.require(:knowledge_entry)).permit(:title, :body, :content_type, :source, :status, tags: [])
  end

  def entry_data(entry)
    entry.attributes.slice('id', 'title', 'body', 'content_type', 'tags', 'source', 'status',
                           'created_at', 'updated_at', 'published_at', 'created_by_id', 'updated_by_id')
         .merge('can_edit' => editable?(entry), 'can_publish' => administrator?)
  end
end
