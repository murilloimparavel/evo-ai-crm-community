# frozen_string_literal: true

class Webhooks::BotRuntimeController < ActionController::API
  before_action :validate_secret

  def postback
    conversation = Conversation.find_by(display_id: params[:conversation_display_id])
    return render json: { error: 'Conversation not found' }, status: :not_found unless conversation

    bot = find_active_agent_bot(conversation)
    return render json: { error: 'No active agent bot for this conversation' }, status: :not_found unless bot

    content, media = normalized_content
    return render json: { error: 'Content is required' }, status: :bad_request if content.blank? && media.blank?

    message = postback_message(conversation, bot, content, media)
    render_result(message, conversation)
  rescue KnowledgeRuntime::ResponseProvenance::Denied
    head :forbidden
  end

  private

  # This callback stays inside ResponseProvenance.record!: verify the signed
  # provenance before looking up a previously delivered runtime response.
  def create_runtime_reply(bot, conversation, content, **options)
    delivery_id = params[:runtime_delivery_id].to_s
    return AgentBots::MessageCreator.new(bot).create_bot_reply(content, conversation, **options) if delivery_id.blank?
    raise ActionController::BadRequest, 'Invalid runtime delivery ID' if delivery_id.bytesize > 200

    conversation.with_lock do
      existing = conversation.messages.where(sender: bot)
                             .where("content_attributes ->> 'runtime_delivery_id' = ?", delivery_id).first
      next existing if existing

      attributes = (options[:content_attributes] || {}).merge(runtime_delivery_id: delivery_id)
      AgentBots::MessageCreator.new(bot).create_bot_reply(content, conversation, **options, content_attributes: attributes)
    end
  end

  def normalized_content
    content = params[:content].to_s
    media = resolve_media(content)
    content = strip_media_urls(content, media) if media.present? && params[:attachments].blank?
    [content, media]
  end

  def postback_message(conversation, bot, content, media)
    content_type = params[:content_type].presence || 'text'
    create_reply = lambda do
      create_runtime_reply(bot, conversation, content, force: params[:force] == true,
                                                       content_type: content_type,
                                                       content_attributes: select_attributes(content_type), media: media)
    end
    return create_reply.call if params[:knowledge_provenance].blank?

    validate_provenance_postback!(media, content_type)
    KnowledgeRuntime::ResponseProvenance.record!(token: params[:knowledge_provenance], content: content,
                                                 conversation: conversation, bot: bot, &create_reply)
  end

  def validate_provenance_postback!(media, content_type)
    raise KnowledgeRuntime::ResponseProvenance::Denied unless ENV['KNOWLEDGE_RESPONSE_PROVENANCE_ENABLED'] == 'true' &&
                                                              BotRuntime::Config.secret.to_s.bytesize >= 32 && media.empty? && content_type == 'text'
  end

  def select_attributes(content_type)
    return nil unless content_type == 'input_select' && params[:items].present?

    { items: params[:items].map { |item| { title: item[:title].to_s, value: item[:value].to_s } } }
  end

  def render_result(message, conversation)
    if message
      Rails.logger.info "[BotRuntime::Postback] Message created: #{message.id} conversation=#{conversation.display_id}"
      render json: { status: 'sent' }, status: :ok
    else
      Rails.logger.warn "[BotRuntime::Postback] Message creation failed: conversation=#{conversation.display_id}"
      render json: { error: 'Message creation failed' }, status: :unprocessable_entity
    end
  end

  VALID_MEDIA_FILE_TYPES = %w[image audio video file].freeze

  # Returns [{ url:, file_type: }] from the structured payload (bot_runtime) or,
  # as a fallback, extracted from the text content (MediaUrlExtractor).
  def resolve_media(content)
    if params[:attachments].present?
      Array(params[:attachments]).filter_map do |att|
        url = att[:url].to_s
        file_type = att[:file_type].to_s
        next if url.blank?
        next unless VALID_MEDIA_FILE_TYPES.include?(file_type) # F6: drop invalid file_type

        { url: url, file_type: file_type }
      end
    else
      AgentBots::MediaUrlExtractor.call(content)[:media]
    end
  end

  # When media came from text extraction, remove those URLs from the text so the
  # link is not duplicated as plain text alongside the rendered media.
  def strip_media_urls(content, _media)
    AgentBots::MediaUrlExtractor.call(content)[:text]
  end

  def validate_secret
    expected_secret = BotRuntime::Config.secret

    # Skip validation when no secret is configured (development/testing)
    return if expected_secret.blank?

    provided_secret = request.headers['X-Bot-Runtime-Secret']
    return if provided_secret == expected_secret

    render json: { error: 'Unauthorized' }, status: :unauthorized
  end

  def find_active_agent_bot(conversation)
    inbox = conversation.inbox
    agent_bot_inbox = inbox.agent_bot_inbox
    return nil unless agent_bot_inbox&.active?

    agent_bot_inbox.agent_bot
  end
end
