module AgentBots
  class SessionSyncAgentResolver
    def initialize(agent_bot)
      @agent_bot = agent_bot
    end

    def call
      configured_agent_id || outgoing_url_agent_id
    end

    private

    def configured_agent_id
      config = @agent_bot.bot_config
      config['agent_id'].to_s if config.is_a?(Hash) && config['agent_id'].present?
    end

    def outgoing_url_agent_id
      outgoing_url = @agent_bot.outgoing_url
      return if outgoing_url.blank?

      match = outgoing_url.match(%r{/api/v1/a2a/([^/?]+)})
      return match[1] if match

      fallback_agent_id(outgoing_url)
    end

    def fallback_agent_id(outgoing_url)
      uri = URI.parse(outgoing_url)
      path_segments = uri.path.split('/').reject(&:empty?)
      a2a_index = path_segments.index('a2a')
      path_segments[a2a_index + 1] if a2a_index
    rescue URI::InvalidURIError
      nil
    end
  end
end
