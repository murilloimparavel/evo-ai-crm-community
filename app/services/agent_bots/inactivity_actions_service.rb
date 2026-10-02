class AgentBots::InactivityActionsService
  def initialize(conversation, agent_bot)
    @conversation = conversation
    @agent_bot = agent_bot
    @inbox = conversation.inbox
  end

  def process
    return unless should_process?

    Rails.logger.info "[InactivityActions] Processing conversation #{@conversation.id}"

    inactivity_actions = get_sorted_actions
    return if inactivity_actions.empty?

    time_inactive_minutes = calculate_inactive_time_minutes
    last_incoming = @conversation.messages.incoming.order(created_at: :desc).first
    return unless last_incoming
    return unless cycle_started_after_activation?(last_incoming)

    Rails.logger.info "[InactivityActions] Time inactive: #{time_inactive_minutes} minutes (since last incoming message at #{last_incoming&.created_at})"

    pending_execution = InactivityActionExecution.for_conversation(@conversation.id).pending.order(:created_at).first
    if pending_execution
      pending_result = process_pending_execution(pending_execution, last_incoming)
      return unless pending_result == :continue
    end

    action_to_execute = find_action_to_execute(inactivity_actions, time_inactive_minutes)
    return unless action_to_execute

    execute_action(action_to_execute, last_incoming)
  end

  private

  def should_process?
    # Só processa se:
    # 1. Conversa está aberta ou pendente
    # 2. Tem inbox ativo
    # 3. Tem bot configurado
    # 4. Bot tem ações de inatividade configuradas
    # 5. Não tem agente humano assignado (opcional - pode ajustar conforme necessário)

    unless @conversation.open? || @conversation.pending?
      Rails.logger.debug "[InactivityActions] Skipping - conversation not open/pending (status: #{@conversation.status})"
      return false
    end

    unless @inbox.present?
      Rails.logger.debug "[InactivityActions] Skipping - no inbox"
      return false
    end

    unless @agent_bot.present?
      Rails.logger.debug "[InactivityActions] Skipping - no agent bot"
      return false
    end

    inactivity_config = @agent_bot.bot_config&.dig('inactivity_actions')
    unless inactivity_config.present? && inactivity_config.is_a?(Array) && inactivity_config.any?
      Rails.logger.debug "[InactivityActions] Skipping - no inactivity actions configured"
      return false
    end

    # A human assignment means the conversation is under manual ownership.
    return false if @conversation.assignee_id.present?

    true
  end

  def get_sorted_actions
    actions = @agent_bot.bot_config&.dig('inactivity_actions')
    return [] unless actions.is_a?(Array)

    valid_actions = actions.select do |action|
      valid = action.is_a?(Hash) &&
              action['minutes'].to_s.match?(/\A[1-9]\d*\z/) &&
              %w[interact finalize].include?(action['action'])
      Rails.logger.warn "[InactivityActions] Ignoring invalid action configuration for bot #{@agent_bot.id}" unless valid
      valid
    end

    # Configuration order is irrelevant; cadence is always chronological.
    valid_actions.sort_by { |action| action['minutes'].to_i }
  end

  # A newly enabled global cadence must not message customers whose current
  # inactivity cycle began before activation. The listener resets executions
  # on the next incoming customer message, which then starts an eligible cycle.
  def cycle_started_after_activation?(last_incoming)
    activation_value = @agent_bot.bot_config&.dig('inactivity_actions_active_from')
    return true if activation_value.blank? # Preserve legacy configurations.

    activation_time = Time.zone.parse(activation_value.to_s)
    return false unless activation_time

    last_incoming.created_at >= activation_time
  rescue ArgumentError, TypeError => e
    Rails.logger.error "[InactivityActions] Invalid activation timestamp for bot #{@agent_bot.id}: #{e.class}"
    false
  end

  def calculate_inactive_time_minutes
    # Calcula inatividade baseado na última mensagem INCOMING (do cliente)
    # Ignora mensagens do bot para evitar resetar o timer de inatividade
    last_incoming_message = @conversation.messages.incoming.order(created_at: :desc).first
    last_activity = last_incoming_message&.created_at || @conversation.created_at

    time_diff_seconds = Time.current - last_activity
    (time_diff_seconds / 60.0).floor
  end

  def find_action_to_execute(actions, time_inactive_minutes)
    # Pega o último índice de ação executada
    last_executed_index = InactivityActionExecution.last_action_index_for(@conversation.id)

    Rails.logger.info "[InactivityActions] Last executed action index: #{last_executed_index}"

    due_action = nil
    actions.each_with_index do |action, index|
      action_time = action['minutes'].to_i

      # Pula ações já executadas
      next if index <= last_executed_index

      # Se o tempo de inatividade já passou do tempo da ação
      if time_inactive_minutes >= action_time
        Rails.logger.info "[InactivityActions] Found action to execute: index #{index}, type: #{action['action']}, time: #{action_time} min"
        due_action = { config: action, index: index }
      end
    end

    # If the scheduler was delayed across several thresholds, execute only the
    # latest currently due step. Earlier steps are superseded, avoiding a
    # minute-by-minute catch-up sequence of stale nudges.
    return due_action if due_action

    Rails.logger.debug "[InactivityActions] No action to execute at this time"
    nil
  end

  def execute_action(action_data, last_incoming, execution = nil)
    action_config = action_data[:config]
    action_index = action_data[:index]
    action_type = action_config['action'] # 'interact' or 'finalize'

    Rails.logger.info "[InactivityActions] Executing action #{action_index}: #{action_type}"

    # Reserve the unique action slot before calling the model. The unique DB
    # index prevents overlapping scheduler jobs from sending the same step.
    execution ||= reserve_execution(action_config, action_index, action_type, last_incoming)
    unless execution
      Rails.logger.info "[InactivityActions] Action already reserved or executed, skipping"
      return
    end

    case action_type
    when 'interact'
      execute_interact_action(action_config, action_index, execution, last_incoming)
    when 'finalize'
      execute_finalize_action(action_config, action_index, execution, last_incoming)
    else
      Rails.logger.error "[InactivityActions] Unknown action type: #{action_type}"
      execution.update!(execution_status: 'failed')
    end
  rescue StandardError => e
    # Keep an ambiguous attempt reserved. A retry first checks for an outgoing
    # message bearing this execution ID before it calls the agent again.
    Rails.logger.error "[InactivityActions] Action #{action_index} failed: #{e.class}: #{e.message}"
    raise
  end

  def execute_interact_action(action_config, action_index, execution, last_incoming)
    Rails.logger.info "[InactivityActions] Executing interact action"

    # `intent` is a prompt for contextual AI copy, not a literal message. Keep
    # the existing direct-message behavior for webhook/n8n providers.
    configured_message = if @agent_bot.evo_ai_provider?
                           action_config['intent'].presence || action_config['message']
                         else
                           action_config['message']
                         end

    # Se tem mensagem configurada E agente é evo_ai_provider, envia para a IA gerar mensagem contextualizada
    # Caso contrário, usa a mensagem configurada diretamente
    if @agent_bot.evo_ai_provider?
      sent = send_to_ai_agent(configured_message, action_config, action_index, execution, last_incoming)
    else
      # Para outros tipos de bot (webhook, n8n), envia mensagem direta
      sent = send_direct_message(configured_message, action_config, action_index, execution, last_incoming)
    end
    case sent
    when :sent
      record_execution(execution, execution.message_sent.presence || configured_message)
    when :skip
      execution.update!(execution_status: 'failed')
    end
  end

  def send_to_ai_agent(suggested_message, action_config, action_index, execution, last_incoming)
    Rails.logger.info "[InactivityActions] Sending to AI agent for contextual message generation"

    return :skip unless current_for_followup_cycle?(last_incoming)

    # Verifica se a conversa está elegível para resposta do bot
    # A validação completa será feita novamente quando a resposta voltar (no MessageCreator)
    # mas fazemos uma pré-validação aqui para evitar requests desnecessários
    agent_bot_inbox = @inbox.agent_bot_inbox
    if agent_bot_inbox.present? && (skip_reason = agent_bot_inbox.processing_block_reason(@conversation))
      Rails.logger.warn "[InactivityActions] ⚠️  Conversation #{@conversation.id} not eligible: #{skip_reason}"
      Rails.logger.warn "[InactivityActions] Skipping inactivity action to avoid sending request to bot that won't be able to reply"
      return :skip
    end

    # Monta payload especial para evento de inatividade
    payload = build_inactivity_payload(suggested_message, action_config, last_incoming, execution)

    # Usa o HttpRequestService para enviar para o agente
    begin
      response_message = AgentBots::HttpRequestService.new(@agent_bot, payload).perform
      return :pending unless response_message.present?

      execution.message_sent = response_message.content if response_message.respond_to?(:content)

      Rails.logger.info "[InactivityActions] ✅ Inactivity message sent to AI agent successfully"
      Rails.logger.info "[InactivityActions] Note: Bot response will be validated again before creating message (status/labels/ignored_labels check)"
      :sent
    rescue StandardError => e
      Rails.logger.error "[InactivityActions] ❌ Error sending to AI agent: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      :pending
    end
  end

  def send_direct_message(message, action_config, action_index, execution, last_incoming)
    Rails.logger.info "[InactivityActions] Sending direct message"

    return :skip unless current_for_followup_cycle?(last_incoming)

    # Cria mensagem diretamente no sistema
    begin
      message_params = {
        inbox_id: @conversation.inbox_id,
        conversation_id: @conversation.id,
        message_type: :outgoing,
        content: message,
        sender: @agent_bot,
        content_attributes: {
          automation_source: 'inactivity_action',
          action_index: action_index,
          inactivity_execution_id: execution.id
        }
      }

      created_message = ::Messages::MessageBuilder.new(nil, @conversation, message_params).perform
      return :pending unless created_message.present?

      execution.message_sent = created_message.content

      Rails.logger.info "[InactivityActions] ✅ Direct message sent successfully"
      :sent
    rescue StandardError => e
      Rails.logger.error "[InactivityActions] ❌ Error sending direct message: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      :pending
    end
  end

  def current_for_followup_cycle?(source_incoming)
    conversation = @conversation.reload
    latest_incoming = conversation.messages.incoming.order(created_at: :desc).first
    return false unless latest_incoming && source_incoming&.id == latest_incoming.id
    return false if conversation.assignee_id.present?
    return false unless conversation.open? || conversation.pending?

    human_replied = conversation.messages.outgoing
                                  .where(sender_type: 'User', private: false)
                                  .where('created_at > ?', latest_incoming.created_at)
                                  .exists?
    return false if human_replied

    agent_bot_inbox = AgentBotInbox.find_by(agent_bot: @agent_bot, inbox: conversation.inbox)
    agent_bot_inbox.blank? || agent_bot_inbox.processing_block_reason(conversation).nil?
  end

  def build_inactivity_payload(suggested_message, action_config, last_incoming, execution)
    minutes_inactive = [(execution.created_at - last_incoming.created_at) / 60.0, 0].max.floor
    conversation_context = recent_customer_facing_context

    # Build clear prompt for AI to understand it should generate an inactivity re-engagement message
    prompt_message = if suggested_message.present?
      "<system_message>[SYSTEM - INACTIVITY ACTION] The customer has been inactive for #{minutes_inactive} minutes. Generate a proactive message to re-engage the customer and send it directly as your reply. Follow-up intent: #{suggested_message}<recent_customer_facing_context>#{conversation_context}</recent_customer_facing_context><important>Reply ONLY with the message text for the customer. Do NOT use any tools like send_private_message. Do NOT add meta-commentary. Just write the reengagement message directly.</important></system_message>"
    else
      "<system_message>[SYSTEM - INACTIVITY ACTION] The customer has been inactive for #{minutes_inactive} minutes. Generate an appropriate and contextualized message to re-engage the customer in the conversation. Be natural, empathetic, and relevant to the conversation context.<recent_customer_facing_context>#{conversation_context}</recent_customer_facing_context><important>Reply ONLY with the message text for the customer. Do NOT use any tools like send_private_message. Do NOT add meta-commentary. Just write the reengagement message directly.</important></system_message>"
    end

    {
      event: 'inactivity_action',
      id: "inactivity-#{execution.id}",
      message_type: 'incoming',
      content: prompt_message,
      conversation: @conversation.webhook_data.merge(id: @conversation.id),
      conversation_id: @conversation.id, # Use UUID id, not display_id
      inbox: @inbox.webhook_data,
      inbox_id: @inbox.id,
      sender: @conversation.contact.webhook_data,
      contact_id: @conversation.contact.id,
      created_at: execution.created_at.to_i,
      # Metadata específica para ação de inatividade
      inactivity_metadata: {
        action_type: 'interact',
        execution_id: execution.id,
        source_incoming_message_id: last_incoming&.id,
        minutes_inactive: minutes_inactive,
        suggested_message: suggested_message,
        action_config: action_config,
        is_system_prompt: true # Flag para a IA saber que é um prompt do sistema
      }
    }
  end

  def recent_customer_facing_context
    @conversation.messages.where(private: false).order(created_at: :desc).limit(15).reverse.filter_map do |message|
      next unless message.incoming? || message.outgoing?
      next if message.content.blank?

      speaker = if message.incoming?
                  'Cliente'
                elsif message.sender_type == 'AgentBot'
                  'IA'
                else
                  'Atendente'
                end
      "#{speaker}: #{message.content.to_s.truncate(800)}"
    end.join("\n")
  end

  def execute_finalize_action(action_config, action_index, execution, last_incoming)
    Rails.logger.info "[InactivityActions] Executing finalize action - resolving conversation"

    unless current_for_followup_cycle?(last_incoming)
      execution.update!(execution_status: 'failed') if execution.persisted?
      return
    end

    begin
      # Resolve a conversa
      @conversation.resolved!

      # Se tem mensagem configurada, envia antes de finalizar
      if action_config['message'].present?
        message_params = {
          inbox_id: @conversation.inbox_id,
          conversation_id: @conversation.id,
          message_type: :outgoing,
          content: action_config['message'],
          sender: @agent_bot,
          content_attributes: {
            automation_source: 'inactivity_action_finalize',
            action_index: action_index,
            inactivity_execution_id: execution.id
          }
        }

        ::Messages::MessageBuilder.new(nil, @conversation, message_params).perform
      end

      # Registra execução
      record_execution(execution, action_config['message'])

      Rails.logger.info "[InactivityActions] ✅ Conversation finalized successfully"
    rescue StandardError => e
      Rails.logger.error "[InactivityActions] ❌ Error finalizing conversation: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      # The outgoing message may already have been committed before an error
      # surfaced. Leave the reservation for reconciliation on the next run.
    end
  end

  def reserve_execution(action_config, action_index, action_type, last_incoming)
    InactivityActionExecution.create!(
      conversation_id: @conversation.id,
      agent_bot_id: @agent_bot.id,
      action_index: action_index,
      action_type: action_type,
      action_config: action_config,
      message_sent: nil,
      execution_status: 'pending',
      attempt_count: 1,
      source_incoming_message_id: last_incoming&.id,
      executed_at: Time.current
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    nil
  end

  def record_execution(execution, message_sent)
    execution.update!(message_sent: message_sent, execution_status: 'sent', executed_at: Time.current)
    Rails.logger.info "[InactivityActions] Execution recorded: index #{execution.action_index}, type #{execution.action_type}"
  end

  RETRY_LEASE = 3.minutes
  MAX_ATTEMPTS = 3

  def process_pending_execution(execution, last_incoming)
    if execution.source_incoming_message_id != last_incoming&.id
      execution.destroy!
      return :continue
    end

    unless current_for_followup_cycle?(last_incoming)
      execution.update!(execution_status: 'failed')
      return :handled
    end

    sent_message = message_for_execution(execution)
    if sent_message
      record_execution(execution, sent_message.content)
      return :handled
    end

    return :handled if execution.updated_at > RETRY_LEASE.ago

    if execution.attempt_count >= MAX_ATTEMPTS
      execution.update!(execution_status: 'failed')
      Rails.logger.error "[InactivityActions] Giving up execution #{execution.id} after #{execution.attempt_count} attempts"
      return :continue
    end

    claimed = InactivityActionExecution.pending
                                            .where(id: execution.id, attempt_count: execution.attempt_count)
                                            .where('updated_at <= ?', RETRY_LEASE.ago)
                                            .update_all(attempt_count: execution.attempt_count + 1, updated_at: Time.current)
    return :handled unless claimed == 1

    execution.reload
    execute_action({ config: execution.action_config, index: execution.action_index }, last_incoming, execution)
    :handled
  end

  def message_for_execution(execution)
    @conversation.messages.outgoing.find_by("content_attributes ->> 'inactivity_execution_id' = ?", execution.id)
  end
end
