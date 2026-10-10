# frozen_string_literal: true

class WhatsappTemplateDefinition < ApplicationRecord
  has_many :publications, class_name: 'WhatsappTemplatePublication', dependent: :destroy

  validates :name, presence: true, uniqueness: { scope: :language },
                  format: { with: /\A[a-z0-9_]+\z/, message: 'must use lowercase letters, numbers, and underscores' }
  validates :language, :category, :content, presence: true
  validates :category, inclusion: { in: %w[MARKETING UTILITY] }
  validate :components_must_have_supported_shapes

  private

  def components_must_have_supported_shapes
    unless components.is_a?(Array) && components.all? { |component| component.is_a?(Hash) }
      errors.add(:components, 'must be a list of WhatsApp template components')
      return
    end

    allowed_types = %w[HEADER BODY FOOTER BUTTONS]
    errors.add(:components, 'contains an unsupported component') if components.any? { |component| !component['type'].in?(allowed_types) }

    body = components.find { |component| component['type'] == 'BODY' }
    errors.add(:components, 'must include a non-empty text BODY') if body.blank? || body['text'].blank?

    headers = components.select { |component| component['type'] == 'HEADER' }
    errors.add(:components, 'supports text headers only') if headers.any? do |header|
      header['format'] != 'TEXT' || header['text'].blank?
    end
    errors.add(:components, 'does not support variables in text headers yet') if headers.any? do |header|
      header['text'].to_s.match?(/\{\{\s*[a-zA-Z0-9_.]+\s*\}\}/)
    end

    footers = components.select { |component| component['type'] == 'FOOTER' }
    errors.add(:components, 'does not support variables in footers') if footers.any? do |footer|
      footer['text'].to_s.match?(/\{\{\s*[a-zA-Z0-9_.]+\s*\}\}/)
    end

    body_text = components.select { |component| component['type'] == 'BODY' }.map { |component| component['text'].to_s }.join(' ')
    tokens = body_text.scan(/\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}/).flatten
    has_positional = tokens.any? { |token| token.match?(/\A\d+\z/) }
    named_tokens = tokens.reject { |token| token.match?(/\A\d+\z/) }
    errors.add(:components, 'cannot mix named and positional variables') if has_positional && named_tokens.any?
    positional_tokens = tokens.select { |token| token.match?(/\A\d+\z/) }.uniq.map(&:to_i).sort
    if has_positional && positional_tokens != (1..positional_tokens.length).to_a
      errors.add(:components, 'positional variables must be numbered consecutively from {{1}}')
    end
    errors.add(:components, 'named variables must start with a letter or underscore and contain only letters, numbers, and underscores') if named_tokens.any? do |token|
      !token.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/)
    end

    buttons_component = components.find { |component| component['type'] == 'BUTTONS' }
    buttons = buttons_component&.dig('buttons') || []
    allowed_buttons = %w[QUICK_REPLY URL PHONE_NUMBER]
    if !buttons.is_a?(Array) || buttons.length > 3 || buttons.any? do |button|
      !button.is_a?(Hash) || !button['type'].in?(allowed_buttons) || button['text'].blank? ||
        (button['type'] == 'URL' && (button['url'].blank? || button['url'].to_s.include?('{{'))) ||
        (button['type'] == 'PHONE_NUMBER' && button['phone_number'].blank?) ||
        (button['type'] == 'QUICK_REPLY' && button['url'].present?)
    end
      errors.add(:components, 'contains unsupported or incomplete buttons')
    end
  end
end
