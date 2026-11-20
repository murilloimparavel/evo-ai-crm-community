# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module BotRuntime
  class Client
    CIRCUIT_BREAKER = CircuitBreaker.new(max_failures: 5, reset_timeout: 30)

    def send_event(event)
      response = CIRCUIT_BREAKER.call do
        perform_request(event)
      end
      # A blocked conversation is a successful service response, not a service outage.
      raise TurnBlockedError, 'Conversation requires reconciliation' if blocked_turn?(response)

      response
    end

    private

    def perform_request(event)
      uri = URI.parse("#{BotRuntime::Config.url}/events")

      http = http_for(uri)

      request = Net::HTTP::Post.new(uri.path)
      request['Content-Type'] = 'application/json'
      request['X-Bot-Runtime-Secret'] = BotRuntime::Config.secret
      request.body = event.to_json

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess) || blocked_turn?(response)
        raise RequestError, "Bot Runtime responded with #{response.code}: #{response.body}"
      end

      response
    end

    def http_for(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = BotRuntime::Config.timeout
      http.read_timeout = BotRuntime::Config.timeout
      http
    end

    def blocked_turn?(response)
      return false unless response.code.to_s == '409'

      JSON.parse(response.body.to_s)['code'] == 'ERR_TURN_BLOCKED'
    rescue JSON::ParserError, TypeError
      false
    end

    class RequestError < StandardError; end
    class TurnBlockedError < StandardError; end
  end
end
