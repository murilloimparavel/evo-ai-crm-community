module AgentBots
  class SessionSyncHttpClient
    def request(method, endpoint, body = nil, headers:)
      base_url = ENV.fetch('EVO_AI_PROCESSOR_URL', 'http://localhost:8000')
      uri = URI("#{base_url}#{endpoint}")
      Rails.logger.debug { "[SessionSync] Making #{method.to_s.upcase} request to #{uri}" }
      response = configure_http_client(uri).request(build_http_request(method, uri, headers, body))
      log_response(response)
      response
    end

    def self.timeout_setting(name, default, max:)
      value = Integer(ENV.fetch(name, default.to_s), 10)
      value.clamp(1, max)
    rescue ArgumentError, TypeError
      default
    end

    private

    def configure_http_client(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.read_timeout = self.class.timeout_setting('EVO_AI_PROCESSOR_READ_TIMEOUT_SECONDS', 5, max: 30)
      http.open_timeout = self.class.timeout_setting('EVO_AI_PROCESSOR_OPEN_TIMEOUT_SECONDS', 2, max: 10)
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

    def log_response(response)
      Rails.logger.debug { "[SessionSync] Response: #{response.code} #{response.message}" }
      Rails.logger.debug { "[SessionSync] Response body: #{response.body}" } if response.body.present?
    end
  end
end
