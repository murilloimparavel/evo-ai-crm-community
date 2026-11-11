class KnowledgeAgentAccessProfile < ApplicationRecord
  validates :account_scope, :external_agent_id, presence: true
  validates :external_agent_id, uniqueness: { scope: :account_scope }
end
