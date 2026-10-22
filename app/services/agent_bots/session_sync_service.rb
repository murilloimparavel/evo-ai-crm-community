module AgentBots
  class SessionSyncService
    def initialize(conversation)
      @conversation = conversation
      @inbox = conversation.inbox
      @agent_bot = @inbox&.agent_bot
    end

    def self.create_session_for_conversation(conversation)
      new(conversation).create_session
    end

    def self.delete_session_for_conversation(conversation)
      new(conversation).delete_session
    end

    def self.add_event_for_message(message)
      new(message.conversation).add_message_event(message)
    end

    def create_session
      return unless should_sync?

      agent_id = extract_agent_id
      return false unless agent_id

      session_id = build_session_id
      contact_id = @conversation.contact_id.to_s

      Rails.logger.info "[SessionSync] Creating session #{session_id} for conversation #{@conversation.id}"

      body = { session_id: session_id, user_id: contact_id, metadata: build_session_metadata }
      send_sync_request(:post, "/api/v1/sessions/sync/#{agent_id}", body, 'create', session_id)
    end

    def delete_session
      return unless should_sync?

      agent_id = extract_agent_id
      return false unless agent_id

      session_id = build_session_id

      Rails.logger.info "[SessionSync] Deleting session #{session_id} for conversation #{@conversation.id}"
      Rails.logger.info "[SessionSync] Agent bot ID: #{@agent_bot&.id}, API key present: #{@agent_bot&.api_key.present?}"

      headers = build_headers
      log_request_headers(headers)
      send_sync_request(:delete, "/api/v1/sessions/sync/#{session_id}", nil, 'delete', session_id, headers: headers)
    end

    def add_message_event(message)
      return unless should_sync?

      agent_id = extract_agent_id
      return false unless agent_id

      session_id = build_session_id

      Rails.logger.info "[SessionSync] Adding event to session #{session_id} for message #{message.id}"
      body = message_event_payload(message)
      send_sync_request(:post, "/api/v1/sessions/#{session_id}/events", body, 'event', session_id)
    end

    private

    def should_sync?
      return false unless @inbox&.active_bot?
      return false unless @agent_bot
      return false if extract_agent_id.blank?
      return false if @conversation.contact_id.blank?

      true
    end

    def extract_agent_id
      AgentBots::SessionSyncAgentResolver.new(@agent_bot).call
    end

    def message_event_payload(message)
      human_agent_reply = !message.incoming? && message.sender_type == 'User'
      content = extract_message_content(message)
      content = "[Mensagem do atendente humano] #{content}" if human_agent_reply

      {
        author: message_author(message, human_agent_reply),
        content: content,
        role: message.incoming? ? 'user' : 'model',
        timestamp: message.created_at.to_f,
        user_id: @conversation.contact_id.to_s,
        invocation_id: "crm-message-#{message.id}"
      }
    end

    def message_author(message, human_agent_reply)
      return 'user' if message.incoming?
      return 'human_agent' if human_agent_reply

      'assistant'
    end

    def send_sync_request(method, endpoint, body, action, session_id, headers: nil)
      response = make_request(method, endpoint, body, headers: headers)
      log_sync_response(response, action, session_id)
    rescue StandardError => e
      Rails.logger.error "[SessionSync] ❌ Error #{action}: #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n")
      false
    end

    def log_sync_response(response, action, session_id)
      return log_sync_success(action, session_id) if successful_response?(response, action)

      Rails.logger.error "[SessionSync] ❌ Failed to #{action}: #{response&.code} #{response&.body}"
      false
    end

    def successful_response?(response, action)
      return false unless response

      accepted_codes = action == 'delete' ? %w[200 204] : %w[200 201]
      accepted_codes.include?(response.code)
    end

    def log_sync_success(action, session_id)
      Rails.logger.info "[SessionSync] ✅ #{action.capitalize} completed for session #{session_id}"
      true
    end

    def log_request_headers(headers)
      Rails.logger.debug do
        "[SessionSync] Request headers: #{headers.except('X-API-Key').merge('X-API-Key' => '[REDACTED]')}"
      end
    end

    def build_session_id
      # Session ID format: {conversation.uuid}_{agent_id}
      # Uses the agent_id from outgoing_url (evo-core-service agent ID)
      # This matches the format used in a2a_routes.py: f"{external_id}_{agent_id}"
      agent_id = extract_agent_id
      return nil unless agent_id

      "#{@conversation.id}_#{agent_id}"
    end

    def extract_message_content(message)
      # Extract text content from message
      content = message.content

      # If content is HTML, try to extract plain text
      if content&.include?('<')
        # Simple HTML tag removal (can be improved)
        content = content.gsub(/<[^>]*>/, '')
      end

      content || ''
    end

    def make_request(method, endpoint, body = nil, headers: nil)
      base_url = ENV.fetch('EVO_AI_PROCESSOR_URL', 'http://localhost:8000')
      request_headers = headers || build_headers
      uri = URI("#{base_url}#{endpoint}")
      Rails.logger.debug { "[SessionSync] Making #{method.to_s.upcase} request to #{uri}" }
      response = configure_http_client(uri).request(build_http_request(method, uri, request_headers, body))
      log_http_response(response)
      response
    end

    def log_http_response(response)
      Rails.logger.debug { "[SessionSync] Response: #{response.code} #{response.message}" }
      Rails.logger.debug { "[SessionSync] Response body: #{response.body}" } if response.body.present?
    end

    def configure_http_client(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.read_timeout = timeout_setting('EVO_AI_PROCESSOR_READ_TIMEOUT_SECONDS', 5, max: 30)
      http.open_timeout = timeout_setting('EVO_AI_PROCESSOR_OPEN_TIMEOUT_SECONDS', 2, max: 10)
      http
    end

    def build_http_request(method, uri, headers, body)
      request_class = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }[method]
      raise ArgumentError, "Unsupported HTTP method: #{method}" unless request_class

      request = request_class.new(uri.path, headers)
      request.body = body.to_json if body
      Rails.logger.debug { "[SessionSync] Request body: #{body.to_json}" } if body
      request
    end

    def timeout_setting(name, default, max:)
      value = Integer(ENV.fetch(name, default.to_s), 10)
      value.clamp(1, max)
    rescue ArgumentError, TypeError
      default
    end

    def build_session_metadata
      contact = @conversation.contact
      return nil unless contact

      {
        evoai_crm_event: 'conversation.created',
        evoai_crm_data: {
          conversation_id: @conversation.id.to_s,
          conversation_display_id: @conversation.display_id,
          inbox_id: @inbox.id.to_s
        },
        agent_bot_id: @agent_bot.id.to_s,
        agent_bot_name: @agent_bot.name,
        contactId: contact.id.to_s,
        contactName: contact.name,
        inboxId: @inbox.id.to_s,
        contact: AgentBots::SessionSyncContactPayload.new(contact).build
      }
    end

    def build_headers
      {
        'Content-Type' => 'application/json',
        'Accept' => 'application/json',
        'X-API-Key' => AgentBots::CredentialResolution.api_key_for(@agent_bot)
      }
    end
  end
end

