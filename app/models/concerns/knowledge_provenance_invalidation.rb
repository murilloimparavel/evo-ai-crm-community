# frozen_string_literal: true

module KnowledgeProvenanceInvalidation
  extend ActiveSupport::Concern

  FIELDS = %w[content processed_message_content content_attributes content_type private sender_type sender_id message_type conversation_id
              inbox_id].freeze

  included do
    before_update :invalidate_knowledge_response_provenance
  end

  private

  def invalidate_knowledge_response_provenance
    return unless KnowledgeResponseProvenance.table_exists?
    return unless changes_to_save.keys.intersect?(FIELDS)

    # Restoring the original text later must not revive a previously edited
    # response. Status-only delivery acknowledgements do not revoke its proof.
    KnowledgeResponseProvenance.find_by(message_id: id)&.update!(reusable: false)
  end
end
