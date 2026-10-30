# frozen_string_literal: true

# Public conversation numbers and UUIDs are separate namespaces. Never let the
# database cast an arbitrary string (e.g. "2a...") into a public number.
class Pipelines::ItemIdentityResolver
  class AmbiguousIdentity < StandardError; end

  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  DECIMAL = /\A[0-9]+\z/

  def initialize(pipeline)
    @pipeline = pipeline
  end

  def conversation(identifier)
    return Conversation.find_by(id: identifier) if uuid?(identifier)

    number = public_number(identifier)
    Conversation.find_by(display_id: number) if number
  end

  # Only the legacy conversation actions accept conversation UUID/public number
  # aliases. Ordinary card updates keep their card-UUID-only contract.
  def item(identifier, allow_conversation: false)
    card = @pipeline.pipeline_items.find_by(id: identifier) if uuid?(identifier)
    return card unless allow_conversation

    target = conversation(identifier)
    return card unless target

    conversation_card = unique_item(@pipeline.pipeline_items.where(conversation_id: target.id))
    if card && (card.conversation_id != target.id || (conversation_card && card.id != conversation_card.id))
      raise AmbiguousIdentity
    end

    card || conversation_card
  end

  def current_item(conversation)
    local = unique_item(conversation.pipeline_items.active.where(pipeline_id: @pipeline.id))
    local || unique_item(conversation.pipeline_items.active)
  end

  private

  def uuid?(identifier)
    identifier.is_a?(String) && UUID.match?(identifier)
  end

  def public_number(identifier)
    return unless identifier.is_a?(String) || identifier.is_a?(Integer)

    value = identifier.to_s
    return unless DECIMAL.match?(value)

    # display_id is currently a signed PostgreSQL integer. Derive its actual
    # bound from the column so a future bigint migration retains the contract.
    max = (1 << ((Conversation.columns_hash.fetch('display_id').limit * 8) - 1)) - 1
    digits = value.sub(/\A0+/, '')
    return if digits.empty? || digits.length > max.to_s.length

    number = digits.to_i
    number if number <= max
  end

  def unique_item(scope)
    active = scope.active.limit(2).to_a
    raise AmbiguousIdentity if active.length > 1
    return active.first if active.any?

    items = scope.limit(2).to_a
    raise AmbiguousIdentity if items.length > 1

    items.first
  end
end
