class AgentBots::ResponseProcessor
  def initialize(agent_bot, payload)
    @agent_bot = agent_bot
    @payload = payload
  end

  def process(response)
    return unless response

    status_code = response.code.to_i
    Rails.logger.info "[AgentBot HTTP] Response Status: #{response.code} #{response.message}"

    if success_response?(status_code)
      handle_success_response(response)
    else
      handle_error_response(response)
    end
  end

  private

  def success_response?(status_code)
    status_code >= 200 && status_code < 300
  end

  def handle_success_response(response)
    Rails.logger.info "[AgentBot HTTP] Success: #{response.code}"

    begin
      parsed_response = JSON.parse(response.body)
      Rails.logger.info "[AgentBot HTTP] Parsed Response: #{parsed_response}"
      process_bot_response(parsed_response)
    rescue JSON::ParserError => e
      Rails.logger.error "[AgentBot HTTP] JSON parsing failed: #{e.message}"
    end
  end

  def handle_error_response(response)
    Rails.logger.error "[AgentBot HTTP] Error Response: #{response.code} - #{response.body}"
  end

  def process_bot_response(parsed_response)
    artifacts = extract_artifacts(parsed_response)
    return unless artifacts

    extracted = extract_content_from_artifacts(artifacts)
    text_content = extracted[:text]
    return unless text_content

    conversation = AgentBots::ConversationFinder.new(@agent_bot, @payload).find_conversation
    return unless conversation
    return if stale_inactivity_response?(conversation)

    execution_id = inactivity_execution_id
    if execution_id.present?
      existing_message = message_for_inactivity_execution(conversation, execution_id)
      return existing_message if existing_message
    end

    select_part = extracted[:select]
    select_items = select_part&.dig('items')

    # Check if text segmentation is enabled for this agent bot
    if execution_id.blank? && select_items.blank? && @agent_bot.text_segmentation_enabled && ['evo_ai_provider', 'n8n_provider'].include?(@agent_bot.bot_provider)
      process_segmented_response(text_content, conversation)
    else
      # Process as a single message with signature
      final_content = build_message_with_signature(text_content)
      Rails.logger.info "[AgentBot HTTP] Bot Response Message: #{final_content}"
      
      message_creator = AgentBots::MessageCreator.new(@agent_bot)
      content_type = select_items.present? ? 'input_select' : 'text'
      content_attributes = select_items.present? ? { items: select_items } : nil
      if execution_id.present?
        content_attributes = (content_attributes || {}).merge(
          automation_source: 'inactivity_action',
          inactivity_execution_id: execution_id
        )
      end
      message = message_creator.create_bot_reply(final_content, conversation, content_type: content_type, content_attributes: content_attributes)

      # Keep the existing fallback for ordinary agent replies. The inactivity
      # path remains guarded above and cannot force-send a stale follow-up.
      unless message || execution_id.present?
        Rails.logger.info "[AgentBot HTTP] Message creation failed (conversation not eligible, e.g., after transfer), attempting force create..."
        message = message_creator.create_bot_reply(final_content, conversation, force: true, content_type: content_type, content_attributes: content_attributes)
      end
      
      message
    end
  end

  def extract_artifacts(parsed_response)
    artifacts = parsed_response.dig('result', 'artifacts')
    return unless artifacts&.any?

    artifacts
  end

  def extract_content_from_artifacts(artifacts)
    text = nil
    select = nil

    artifacts.each do |artifact|
      next unless artifact.is_a?(Hash) && artifact['parts'].is_a?(Array)

      artifact['parts'].each do |part|
        next unless part.is_a?(Hash)

        if text.nil? && part['type'] == 'text' && part['text'].present?
          text = part['text']
        end

        if select.nil? && part['type'] == 'select'
          select = part
        end
      end
    end

    { text: text, select: select }
  end

  # Inactivity requests can take long enough for a customer or human agent to
  # reply while the model is generating. Revalidate at the final message-write
  # boundary so an obsolete nudge cannot be delivered.
  def stale_inactivity_response?(conversation)
    metadata = @payload[:inactivity_metadata] || @payload['inactivity_metadata']
    return false unless metadata.present?

    source_id = metadata[:source_incoming_message_id] || metadata['source_incoming_message_id']
    latest_incoming = conversation.messages.incoming.order(created_at: :desc).first
    return true if source_id.blank? || latest_incoming&.id.to_s != source_id.to_s
    return true if conversation.assignee_id.present?

    human_replied = conversation.messages.outgoing
                               .where(sender_type: 'User', private: false)
                               .where('created_at > ?', latest_incoming.created_at)
                               .exists?
    return true if human_replied

    agent_bot_inbox = AgentBotInbox.find_by(agent_bot: @agent_bot, inbox: conversation.inbox)
    block_reason = agent_bot_inbox&.processing_block_reason(conversation)
    return true if block_reason.present?

    false
  rescue StandardError => e
    # On validation errors fail closed: a follow-up is less important than
    # accidentally messaging after a handoff or a fresh customer reply.
    Rails.logger.error "[AgentBot HTTP] Could not validate inactivity response: #{e.class}: #{e.message}"
    true
  end

  def inactivity_execution_id
    metadata = @payload[:inactivity_metadata] || @payload['inactivity_metadata']
    metadata&.dig(:execution_id) || metadata&.dig('execution_id')
  end

  def message_for_inactivity_execution(conversation, execution_id)
    conversation.messages.outgoing.find_by("content_attributes ->> 'inactivity_execution_id' = ?", execution_id)
  end

  def process_segmented_response(text_content, conversation)
    # Create segmentation service with bot's configuration
    segmentation_service = AgentBots::TextSegmentationService.new(
      @agent_bot.text_segmentation_limit || 300,
      @agent_bot.text_segmentation_min_size || 50
    )

    # Segment the text
    segments = segmentation_service.segment_text(text_content)

    Rails.logger.info "[AgentBot HTTP] Text segmented into #{segments.length} parts"
    segments.each_with_index do |segment, index|
      Rails.logger.info "[AgentBot HTTP] Segment #{index + 1}: #{segment[0..100]}#{'...' if segment.length > 100}"
    end

    # Create messages using the segmented message creator
    message_creator = AgentBots::SegmentedMessageCreator.new(@agent_bot)
    message_creator.create_messages(segments, conversation)
  end

  def build_message_with_signature(content)
    return content if @agent_bot.message_signature.blank?

    # Add signature at the top with two line breaks before the message
    "#{@agent_bot.message_signature}\n\n#{content}"
  end
end
