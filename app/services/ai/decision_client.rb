# frozen_string_literal: true

module Ai
  # Reuses the existing scoped credential registry. Endpoints are capability
  # allowlisted: credentials are never sent to an arbitrary configured host.
  class DecisionClient
    MODELS = [{ id: JevClient::OPENROUTER_MODEL, label: 'TypeSafe Jev 1.14', provider: 'openrouter' }.freeze].freeze
    OPENROUTER_BASE_URLS = %w[https://openrouter.ai https://openrouter.ai/api https://openrouter.ai/api/v1].freeze

    def self.status
      endpoint = resolve
      { configured: valid?(endpoint), provider: 'openrouter' }
    rescue StandardError
      { configured: false, provider: 'openrouter' }
    end

    def self.for_pipeline(model:, live_authorized: false, transport: nil)
      raise ArgumentError, 'unsupported_decision_model' unless model == JevClient::OPENROUTER_MODEL

      endpoint = resolve
      key = valid?(endpoint) ? endpoint.key : nil
      JevClient.new(api_key: key, provider: 'openrouter', live_authorized: live_authorized && key.present?, transport: transport)
    end

    def self.resolve
      return nil unless Ai::Credential.table_exists?

      ApplicationRecord.transaction(requires_new: true) do
        CredentialResolver.resolve_endpoint(for_consumer: :pipeline_classification)
      end
    rescue StandardError
      nil
    end
    private_class_method :resolve

    def self.valid?(endpoint)
      endpoint&.provider == 'openrouter' && endpoint.key.present? &&
        (endpoint.base_url.blank? || OPENROUTER_BASE_URLS.include?(endpoint.base_url.sub(%r{/+\z}, '')))
    end
    private_class_method :valid?
  end
end
