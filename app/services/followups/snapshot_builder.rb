# frozen_string_literal: true

require 'digest'
require 'json'

module Followups
  class SnapshotBuilder
    MAX_MESSAGES = 8
    MAX_CHARACTERS = 800
    MAX_BYTES = 12 * 1024
    HARD_MAX_MESSAGES = 16
    HARD_MAX_CHARACTERS = 4000
    class Unsafe < StandardError; end

    def initialize(campaign:, execution: nil, classification: nil, conversation: nil, now: Time.current)
      @record = execution || classification
      @execution = execution
      @campaign = campaign
      @conversation = conversation || @record&.conversation
      @now = now
    end

    # Keep the bounded snapshot identity and privacy minimization checks complete and in their audited order.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def call
      @limits = snapshot_limits
      raise Unsafe, 'missing_snapshot_identity' unless @record && @conversation
      raise Unsafe, 'snapshot_identity_mismatch' unless @record.conversation_id == @conversation.id
      raise Unsafe, 'snapshot_inbox_mismatch' unless @campaign.inbox_id == @conversation.inbox_id
      raise Unsafe, 'snapshot_campaign_mismatch' if @record.respond_to?(:followup_campaign_id) && @record.followup_campaign_id != @campaign.id

      source = public_messages.find_by(id: @record.source_incoming_message_id)
      raise Unsafe, 'missing_source_incoming' unless source&.incoming?

      @source = source
      latest_incoming = Eligibility.latest_incoming(@conversation)
      raise Unsafe, 'stale_source_incoming' unless latest_incoming&.id == source.id

      anchor = approved_anchor
      beginning = anchor || public_messages.where(message_type: :outgoing)
                                           .where('created_at <= ?', source.created_at).reorder(created_at: :desc, id: :desc).first
      started_at = beginning&.created_at || @campaign.active_from
      raise Unsafe, 'missing_snapshot_start' unless started_at && (anchor || started_at <= source.created_at)

      messages = public_messages.where('created_at >= ?', started_at).reorder(created_at: :asc, id: :asc).limit(@limits['max_messages'] + 1).to_a
      messages << source if anchor && messages.none? { |message| message.id == source.id }
      messages.sort_by! { |message| [message.created_at, message.id] }
      raise Unsafe, 'snapshot_too_many_messages' if messages.size > @limits['max_messages']
      raise Unsafe, 'missing_mandatory_message' unless messages.any? { |message| message.id == source.id }
      raise Unsafe, 'missing_mandatory_anchor' if anchor && messages.none? { |message| message.id == anchor.id }

      state = { 'content_is_untrusted_data' => true, 'conversation_status' => @conversation.status,
                'messages' => messages.map.with_index { |message, index| serialize(message, index) } }
      context = SnapshotContext.new(@campaign.policy.fetch('snapshot_context', {})).call(conversation: @conversation)
      state['crm'] = context unless context.empty?
      questions = @campaign.pipeline_catalog? ? {} : QuestionValidator.call(@campaign.policy.fetch('classifier').fetch('questions'))
      request_size = JSON.generate(model: Ai::JevClient::MODEL, state: state, questions: questions).bytesize
      raise Unsafe, 'snapshot_too_large' if request_size > @limits['max_request_bytes']

      references = {
        conversation_id: @conversation.id, inbox_id: @conversation.inbox_id,
        contact_id: @conversation.contact_id, campaign_id: @campaign.id,
        pipeline_stage_id: @campaign.pipeline_stage_id,
        pipeline_item_id: if @execution
                            @execution.pipeline_item_id
                          else
                            @conversation.pipeline_items
                                         .where(pipeline_stage_id: @campaign.pipeline_stage_id).pick(:id)
                          end,
        source_incoming_message_id: source.id, anchor_message_id: anchor&.id,
        classification_only: @execution.nil?,
        generation: generation, revision: revision, policy_version: @campaign.policy_version,
        message_digests: messages.map { |message| [message.id, Digest::SHA256.hexdigest(message.content.to_s)] },
        cutoff: @now.iso8601(6)
      }
      valid_until = [@record.expires_at, @campaign.expires_at].compact.min
      raise Unsafe, 'snapshot_expired' unless valid_until && valid_until > @now

      hash = Digest::SHA256.hexdigest(JSON.generate(state: state, references: references.except(:cutoff)))
      { state: state, snapshot_hash: hash, references: references, valid_until: valid_until, classification_only: @execution.nil? }
    rescue Unsafe, SnapshotContext::Invalid, SnapshotContext::InvalidValue => e
      { state: nil, snapshot_hash: nil, references: {}, valid_until: @now, reason: e.message }
    rescue QuestionValidator::Invalid, KeyError
      { state: nil, snapshot_hash: nil, references: {}, valid_until: @now, reason: 'invalid_question_pack' }
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    private

    def snapshot_limits
      defaults = { 'max_messages' => MAX_MESSAGES, 'max_message_characters' => MAX_CHARACTERS, 'max_request_bytes' => MAX_BYTES }
      configured = @campaign.policy.fetch('snapshot_limits', {})
      ceilings = { 'max_messages' => HARD_MAX_MESSAGES, 'max_message_characters' => HARD_MAX_CHARACTERS, 'max_request_bytes' => MAX_BYTES }
      raise Unsafe, 'invalid_snapshot_limits' unless configured.is_a?(Hash) && (configured.keys - defaults.keys).empty?

      configured.each do |key, value|
        raise Unsafe, 'invalid_snapshot_limits' unless value.is_a?(Integer) && value.between?(1, ceilings.fetch(key))
      end
      defaults.merge(configured)
    end

    def public_messages
      @public_messages ||= @conversation.messages.where(private: false, message_type: %i[incoming outgoing])
                                        .where.not(status: :failed).where('created_at <= ?', @now)
                                        .where("COALESCE(content_attributes->>'deleted', 'false') != 'true'")
                                        .where("COALESCE(content_attributes->>'revoked_by_contact', 'false') != 'true'")
                                        .where("COALESCE(additional_attributes->>'cancelled', 'false') != 'true'")
                                        .where("COALESCE(additional_attributes->>'canceled', 'false') != 'true'")
    end

    # Keep the bounded snapshot identity and privacy minimization checks complete and in their audited order.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def approved_anchor
      return unless @execution

      evidence = @execution.followup_anchor_evidence
      anchor = public_messages.find_by(id: @execution.quote_anchor_message_id)
      raise Unsafe, 'approved_anchor_required' unless evidence && anchor&.outgoing? && %w[delivered read].include?(anchor.status)
      raise Unsafe, 'anchor_identity_mismatch' unless evidence.anchor_message_id == anchor.id && evidence.conversation_id == @conversation.id &&
                                                      evidence.followup_campaign_id == @campaign.id &&
                                                      evidence.source_incoming_message_id == @record.source_incoming_message_id
      if @execution.respond_to?(:pipeline_item_id) && evidence.pipeline_item_id != @execution.pipeline_item_id
        raise Unsafe, 'anchor_pipeline_mismatch'
      end
      raise Unsafe, 'anchor_not_verified' unless evidence.verified_by_id && evidence.verified_at && evidence.verified_at <= @now
      raise Unsafe, 'anchor_wrong_order' if anchor.created_at < @source.created_at
      raise Unsafe, 'unknown_multimodal_content' if anchor.attachments.exists?
      raise Unsafe, 'anchor_changed' unless evidence.anchor_digest == EvidenceApproval.digest(anchor)
      if public_messages.where(message_type: :outgoing).where.not(id: anchor.id).exists?(['created_at >= ?', anchor.created_at])
        raise Unsafe, 'anchor_not_current'
      end

      anchor
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    def generation
      return @record.generation if @record.respond_to?(:generation)

      FollowupConversationState.find_by(conversation_id: @conversation.id)&.classification_generation
    end

    def revision
      return @record.revision if @record.respond_to?(:revision)

      @record.authorized_revision
    end

    # Keep the bounded snapshot identity and privacy minimization checks complete and in their audited order.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def serialize(message, index)
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
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    # Keep the bounded snapshot identity and privacy minimization checks complete and in their audited order.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def minimize(content)
      # Normalize before inspection so zero-width separators and fullwidth digits
      # cannot hide secrets. Ambiguous sensitive text aborts the entire request.
      text = content.unicode_normalize(:nfkc).gsub(/[\p{Cf}\p{Cc}]/, ' ')
      text = text.gsub(%r{\b(?:https?://|www\.)\S+}i, '[link]')
      raise Unsafe, 'sensitive_content' if text.match?(/\b(?:bearer|api[_ -]?key|password|senha|token|secret|bank.account)\b/i)

      # A price proposal is ordinary commercial context. An asserted payment or
      # receipt is not evidence of approval and must not authorize a nudge.
      # Keep the audited privacy expression byte-identical; splitting regex escapes can change redaction.
      # rubocop:disable Layout/LineLength
      payment_claim = /\b(?:paguei|pagou|paid|comprovante|receipt|(?:pix|pagamento|payment|cart[aã]o|transfer[eê]ncia|transfer)\s+(?:(?:j[aá]|foi|is|was)\s+)?(?:pago|pag[oa]s?|feito|realizad[oa]|aprovad[oa]|confirmad[oa]|recebid[oa]|sent|made|completed|confirmed|approved)|(?:enviei|mandei|fiz|efetuei|recebi)\s+(?:o\s+|um\s+|a\s+|uma\s+)?(?:pix|pagamento|transfer[eê]ncia|comprovante))\b/i
      # rubocop:enable Layout/LineLength
      raise Unsafe, 'payment_claim_requires_review' if text.match?(payment_claim)

      text = text.gsub(/(?:R\$|US\$|[$€£]|\b(?:BRL|USD|EUR)\b)\s*-?\s*\d(?:[\d.,\u00a0 ]*\d)?/i, '[amount]')
                 .gsub(/\b(total|pre[cç]o|valor|or[cç]amento|price|budget)\s*(?::|de)?\s*\d[\d.,]*/i, '\\1 [amount]')
                 .gsub(/\d+(?:[.,]\d+)?\s*%/, '[percentage]')
                 .gsub(/\b(pix|cart[aã]o|cart[oõ]es|credit.card|debit.card)\b/i, '[payment_method]')
      # References have no decision authority. Remove the identifier while
      # retaining the surrounding statement and any negative or condition.
      # Keep the audited privacy expression byte-identical; splitting regex escapes can change redaction.
      # rubocop:disable Layout/LineLength
      text = text.gsub(/\b((?:reserva|booking|pedido|order|protocolo|reference|or[cç]amento)\s*(?:(?:n[ºo°.]?|id|c[oó]digo|code|confirmation)\s*)?[:#-]?\s*)((?=[A-Z0-9_-]*\d)[A-Z0-9_-]{3,}|(?-i:[A-Z][A-Z0-9_-]{2,}))\b/i) do
        # rubocop:enable Layout/LineLength
        prefix, reference = Regexp.last_match.captures
        preserve = semantic_condition?(reference) ||
                   reference.match?(/\A(?:confirmad[oa]|cancelad[oa]|aprovad[oa]|pendente|confirmed|cancelled|approved|pending)\z/i)
        preserve ? "#{prefix}#{reference}" : "#{prefix}[reference]"
      end
      # Keep the audited privacy expression byte-identical; splitting regex escapes can change redaction.
      # rubocop:disable Layout/LineLength
      text = text.gsub(/\b((?i:op[cç][aã]o|option|produto|product|item|unidade|unit|servi[cç]o|service)\s*\d*\s*[:—-]\s*)(\p{Lu}[\p{L}]+(?:\s+(?:(?:da|de|do|dos|das)\s+)?\p{Lu}[\p{L}]+)*)/u) do
        # rubocop:enable Layout/LineLength
        prefix, product = Regexp.last_match.captures
        semantic_condition?(product) ? "#{prefix}#{product}" : "#{prefix}[product]"
      end

      contact = @conversation.contact
      identities = %i[name middle_name last_name email phone_number tax_id identifier].flat_map do |field|
        value = contact.public_send(field).to_s.unicode_normalize(:nfkc)
        field.to_s.include?('name') ? [value, *value.split] : [value]
      end
      identities = identities.reject { |value| value.length < 2 }.uniq.sort_by { |value| -value.length }
      identities.each { |value| text = text.gsub(/(?<![\p{L}\p{N}])#{Regexp.escape(value)}(?![\p{L}\p{N}])/i, '[identity]') }
      text = text.gsub(%r{[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?\.[A-Z]{2,}}i, '[email]')
                 .gsub(/(?<!\d)(?:\+?\d[\d\s().-]{6,}\d)(?!\d)/, '[number]')
      # Introductions remain ambiguous. Other possible named entities are
      # redacted instead of rejecting an otherwise useful quote wholesale.
      raise Unsafe, 'unresolved_identity' if text.match?(/\b(?:me chamo|meu nome|my name|sou o|sou a)\b/i)

      text = text.gsub(/\b\p{Lu}\p{Ll}{2,}(?:\s+(?:da|de|do|dos|das))?\s+\p{Lu}\p{Ll}{2,}\b/) do |entity|
        semantic_condition?(entity) ? entity : '[entity]'
      end
      raise Unsafe, 'unresolved_identity' if text.include?('@')

      if text.match?(/\b[A-Za-z0-9_-]{24,}\b|\b(?=[A-Za-z0-9_-]{8,}\b)(?=[A-Za-z0-9_-]*\d)(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]+\b/)
        raise Unsafe,
              'unresolved_identifier'
      end

      text
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    def semantic_condition?(text)
      text.match?(/\b(?:n[aã]o|sem|nunca|nenhum[a]?|se|caso|apenas|somente|not|no|never|none|unless|only|if)\b/i)
    end
  end
end
