# frozen_string_literal: true

require 'digest'

module PipelineClassification
  # Shared bounded public-message projection with contact identifiers removed.
  class SnapshotBase
    MAX_MESSAGES = 8
    MAX_BYTES = 12 * 1024
    class Unsafe < StandardError; end

    private

    def public_messages
      @public_messages ||= @conversation.messages.where(private: false, message_type: %i[incoming outgoing])
                                        .where.not(status: :failed).where('created_at <= ?', @now)
                                        .where("COALESCE(content_attributes->>'deleted', 'false') != 'true'")
                                        .where("COALESCE(content_attributes->>'revoked_by_contact', 'false') != 'true'")
                                        .where("COALESCE(additional_attributes->>'cancelled', 'false') != 'true'")
                                        .where("COALESCE(additional_attributes->>'canceled', 'false') != 'true'")
    end

    def serialize(message, index) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      raise Unsafe, 'message_inbox_mismatch' unless message.inbox_id == @conversation.inbox_id
      raise Unsafe, 'unknown_multimodal_content' if message.attachments.exists? || %w[text input_text input_textarea].exclude?(message.content_type)
      raise Unsafe, 'unknown_multimodal_content' if message.content_attributes.to_h['is_unsupported']

      content = message.content.to_s
      raise Unsafe, 'invalid_text_encoding' unless content.valid_encoding?
      raise Unsafe, 'snapshot_message_too_long' if content.length > @limits['max_message_characters']
      raise Unsafe, 'empty_message' if content.strip.empty?

      { 'order' => index, 'role' => message.incoming? ? 'customer' : 'business',
        'delivery' => message.status, 'content' => minimize(content) }
    end

    # Keep useful intent and payment claims while removing identifiers and exact amounts.
    def minimize(content) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      text = content.unicode_normalize(:nfkc).gsub(/[\p{Cf}\p{Cc}]/, ' ')
      raise Unsafe, 'sensitive_content' if text.match?(/\b(?:bearer|api[_ -]?key|password|senha|token|secret|bank.account)\b/i)

      text = text.gsub(%r{\b(?:https?://|www\.)\S+}i, '[link]')
                 .gsub(/(?:R\$|US\$|[$€£]|\b(?:BRL|USD|EUR)\b)\s*-?\s*\d(?:[\d.,\u00a0 ]*\d)?/i, '[amount]')
                 .gsub(/\b(total|pre[cç]o|valor|or[cç]amento|price|budget)\s*(?::|de)?\s*\d[\d.,]*/i, '\\1 [amount]')
                 .gsub(/\d+(?:[.,]\d+)?\s*%/, '[percentage]')

      contact = @conversation.contact
      if contact
        identities = %i[name middle_name last_name email phone_number tax_id identifier].flat_map do |field|
          value = contact.public_send(field).to_s.unicode_normalize(:nfkc)
          field.to_s.include?('name') ? [value, *value.split] : [value]
        end
        identities.reject { |value| value.length < 2 }.uniq.sort_by { |value| -value.length }.each do |value|
          text = text.gsub(/(?<![\p{L}\p{N}])#{Regexp.escape(value)}(?![\p{L}\p{N}])/i, '[identity]')
        end
      end
      text = text.gsub(%r{[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?\.[A-Z]{2,}}i, '[email]')
                 .gsub(/(?<!\d)(?:\+?\d[\d\s().-]{6,}\d)(?!\d)/, '[number]')
      raise Unsafe, 'unresolved_identity' if text.match?(/\b(?:me chamo|meu nome|my name|sou o|sou a)\b/i)

      text = text.gsub(/\b\p{Lu}\p{Ll}{2,}(?:\s+(?:da|de|do|dos|das))?\s+\p{Lu}\p{Ll}{2,}\b/, '[entity]')
      raise Unsafe, 'unresolved_identity' if text.include?('@')

      if text.match?(/\b[A-Za-z0-9_-]{24,}\b|\b(?=[A-Za-z0-9_-]{8,}\b)(?=[A-Za-z0-9_-]*\d)(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]+\b/)
        raise Unsafe,
              'unresolved_identifier'
      end

      text
    end
  end
end
