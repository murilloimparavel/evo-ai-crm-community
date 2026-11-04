# frozen_string_literal: true

require 'json'
require 'net/http'
require 'timeout'
require 'time'
require_relative 'jev_answer_validation'

module Ai
  # Stateless typed classification transport. It has no CRM dependencies and
  # never retries. Billing reservations and retry scheduling belong to callers.
  class JevClient
    include JevAnswerValidation
    MODEL = 'jev-1.14.0'
    ENDPOINT = URI('https://api.typesafe.ai/v1/systemone').freeze
    OPENROUTER_ENDPOINT = URI('https://openrouter.ai/api/v1/systemone').freeze
    OPENROUTER_MODEL = 'typesafe/jev-1.14'
    MAX_REQUEST_BYTES = 12 * 1024
    MAX_RESPONSE_BYTES = 64 * 1024
    DEADLINE_SECONDS = 10
    QUESTION_TYPES = %w[choice noul score].freeze
    class Invalid < StandardError; end

    def initialize(api_key: ENV.fetch('JEV_API_KEY', nil), transport: nil, live_authorized: false, provider: 'typesafe')
      @api_key = api_key
      @transport = transport
      @live_authorized = live_authorized
      @provider = provider
    end

    # Keep the bounded transport/protocol checks together so billing metadata survives schema failures.
    def call(state:, questions:, model: MODEL) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      expected_model = @provider == 'openrouter' ? OPENROUTER_MODEL : MODEL
      return failure('unsupported_model', usage_known: true) unless %w[typesafe openrouter].include?(@provider) && model == expected_model

      validate_questions!(questions)
      body = JSON.generate(model: model, state: state, questions: questions)
      return failure('request_too_large', usage_known: true) if body.bytesize > MAX_REQUEST_BYTES
      unless @transport || (@live_authorized && ENV['JEV_LIVE_REQUESTS_ENABLED'] == 'true' && !@api_key.to_s.empty?)
        return failure('live_requests_disabled', usage_known: true)
      end

      headers = { 'Content-Type' => 'application/json', 'Accept' => 'application/json',
                  'Authorization' => "Bearer #{@api_key}" }
      response = Timeout.timeout(DEADLINE_SECONDS) do
        if @transport
          @transport.call(uri: endpoint, headers: headers, body: body,
                          timeout: DEADLINE_SECONDS, max_response_bytes: MAX_RESPONSE_BYTES)
        else
          request_http(headers, body)
        end
      end
      parse_response(response, questions, expected_model)
    rescue Timeout::Error
      failure('classification_timeout', retryable: true)
    rescue Invalid, JSON::GeneratorError, JSON::ParserError, TypeError, ArgumentError
      failure('invalid_provider_schema')
    rescue IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError
      failure('classification_transport_error', retryable: true)
    end

    private

    def endpoint
      @provider == 'openrouter' ? OPENROUTER_ENDPOINT : ENDPOINT
    end

    # Keep the bounded transport/protocol checks together so billing metadata survives schema failures.
    def request_http(headers, body) # rubocop:disable Metrics/AbcSize
      http = Net::HTTP.new(endpoint.host, endpoint.port)
      http.use_ssl = true
      http.open_timeout = 3
      http.read_timeout = DEADLINE_SECONDS
      http.write_timeout = 3
      http.max_retries = 0
      request = Net::HTTP::Post.new(endpoint.request_uri, headers)
      request.body = body
      http.request(request) do |response|
        buffer = +''
        response.read_body do |chunk|
          raise Invalid if buffer.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES

          buffer << chunk
        end
        return { status: response.code.to_i, headers: { 'retry-after' => response['Retry-After'] }, body: buffer }
      end
    end

    # Keep the bounded transport/protocol checks together so billing metadata survives schema failures.
    def parse_response(response, questions, expected_model) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      raise Invalid unless response.is_a?(Hash) && response[:status].is_a?(Integer)

      status = response[:status]
      unless status == 200
        return failure("provider_http_#{status}", retryable: [429, 529].include?(status),
                                                  retry_after: retry_after(response[:headers]))
      end
      raw = response[:body]
      raise Invalid unless raw.is_a?(String) && raw.valid_encoding? && raw.bytesize <= MAX_RESPONSE_BYTES

      data = JSON.parse(raw)
      usage = data.is_a?(Hash) ? data['usage'] : nil
      tokens = usage.is_a?(Hash) ? usage['input_tokens'] : nil
      known = tokens.is_a?(Integer) && tokens >= 0
      metadata = { input_tokens: known ? tokens : nil, usage_known: known }
      if @provider == 'openrouter'
        cost = usage.is_a?(Hash) ? usage['cost'] : nil
        cost_known = cost.is_a?(Numeric) && cost.finite? && cost >= 0
        metadata[:cost_usd] = cost_known ? cost : nil
        metadata[:cost_known] = cost_known
      end
      begin
        allowed_keys = @provider == 'openrouter' ? %w[answers model usage id provider] : %w[answers model usage]
        raise Invalid unless data.is_a?(Hash) && (data.keys - allowed_keys).empty? && known

        served_model = data['model']
        if @provider == 'openrouter'
          raise Invalid unless served_model.is_a?(String) && %r{\Atypesafe/jev-1\.14(?:-\d{8})?\z}.match?(served_model)
          raise Invalid if data.key?('id') && (!data['id'].is_a?(String) || data['id'].bytesize > 200)
          raise Invalid if data.key?('provider') && data['provider'] != 'TypeSafe'
          raise Invalid unless metadata[:cost_known]
        else
          raise Invalid unless served_model == MODEL
        end
        allowed_usage = @provider == 'openrouter' ? %w[input_tokens output_tokens cost] : %w[input_tokens output_tokens]
        raise Invalid unless (usage.keys - allowed_usage).empty?
        raise Invalid unless usage['output_tokens'].is_a?(Integer) && usage['output_tokens'] >= 0

        answers = data['answers']
        raise Invalid unless answers.is_a?(Hash) && answers.keys.sort == questions.keys.sort

        questions.each { |id, question| validate_answer!(answers[id], question) }
        result = { ok: true, model: expected_model, answers: answers, retryable: false, retry_after: nil }.merge(metadata)
        result[:served_model] = served_model if @provider == 'openrouter'
        result
      rescue Invalid
        failure('invalid_provider_schema', **metadata)
      end
    end

    # Keep the bounded transport/protocol checks together so billing metadata survives schema failures.
    def validate_questions!(questions) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      raise Invalid unless questions.is_a?(Hash) && questions.size.between?(1, 12)

      questions.each do |id, question|
        raise Invalid unless id.is_a?(String) && question.is_a?(Hash)
        raise Invalid unless (question.keys - %w[type instructions criteria]).empty?
        raise Invalid unless QUESTION_TYPES.include?(question['type']) && question.key?('instructions')

        criteria = question['criteria']
        case question['type']
        when 'choice' then raise Invalid unless criteria.is_a?(Hash) && criteria.size.between?(2, 255) && criteria.keys.all?(String)
        when 'noul' then raise Invalid unless criteria.is_a?(Hash) && criteria.keys.sort == %w[false true]
        when 'score' then raise Invalid unless criteria.is_a?(Array) && criteria.size.between?(2, 10)
        end
      end
    end

    def retry_after(headers)
      value = headers.is_a?(Hash) ? (headers['retry-after'] || headers['Retry-After']) : nil
      return if value.nil? || value.to_s.bytesize > 128
      return [value.to_i, 3600].min if value.to_s.match?(/\A\d{1,5}\z/)

      (Time.httpdate(value.to_s) - Time.now.utc).ceil.clamp(0, 3600)
    rescue ArgumentError
      nil
    end

    # Keep the bounded transport/protocol checks together so billing metadata survives schema failures.
    def failure(reason, retryable: false, retry_after: nil, usage_known: false, input_tokens: nil, cost_known: nil, cost_usd: nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/ParameterLists
      result = { ok: false, reason: reason, model: @provider == 'openrouter' ? OPENROUTER_MODEL : MODEL, answers: nil,
                 input_tokens: input_tokens || (usage_known ? 0 : nil),
                 usage_known: usage_known, retryable: retryable, retry_after: retry_after }
      if @provider == 'openrouter'
        local_free = usage_known && (input_tokens.nil? || input_tokens.zero?)
        result[:cost_known] = cost_known.nil? ? local_free : cost_known
        result[:cost_usd] = cost_usd || (cost_known.nil? && local_free ? 0 : nil)
      end
      result
    end
  end
end
