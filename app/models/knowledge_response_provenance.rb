class KnowledgeResponseProvenance < ApplicationRecord
  belongs_to :message, optional: true
  validates :proof_jti, :account_scope, :executor_id, :config_sha256, :body_sha256, presence: true
end
