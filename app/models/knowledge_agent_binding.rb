class KnowledgeAgentBinding < ApplicationRecord
  belongs_to :knowledge_base
  validates :account_scope, :external_agent_id, presence: true
  validate :base_matches_scope

  private

  def base_matches_scope
    errors.add(:knowledge_base, 'belongs to another account') if knowledge_base && knowledge_base.account_scope != account_scope
  end
end
