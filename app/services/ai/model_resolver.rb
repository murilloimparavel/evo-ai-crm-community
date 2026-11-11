# frozen_string_literal: true

class Ai::ModelResolver
  OPENROUTER_PROVIDER_PREFIX = 'openrouter/'
  OPENROUTER_DEFAULT_MODEL = 'openai/gpt-4.1-nano'

  def self.resolve(model, provider:, openrouter_model: nil)
    return model unless provider == 'openrouter'

    normalized = openrouter_model.to_s.strip.presence || model.to_s.strip
    normalized = OPENROUTER_DEFAULT_MODEL if normalized.blank?
    normalized = normalized.delete_prefix(OPENROUTER_PROVIDER_PREFIX)
    return "openai/#{normalized}" if normalized.present? && normalized.exclude?('/')

    normalized
  end
end
