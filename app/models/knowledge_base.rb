class KnowledgeBase < ApplicationRecord
  has_many :knowledge_entries, dependent: :restrict_with_error
  has_many :knowledge_agent_bindings, dependent: :restrict_with_error

  before_validation { self.name = name.strip if name.is_a?(String) }
  validate :reserve_default_name
  validates :account_scope, :name, presence: true
  validates :name, length: { maximum: 200 }, uniqueness: { scope: :account_scope, case_sensitive: false }
  validates :description, length: { maximum: 1000 }, allow_nil: true
  validates :status, inclusion: { in: %w[active archived] }

  private

  def reserve_default_name
    errors.add(:name, 'reserved for the default base') if !legacy_default? && name.to_s.casecmp?('Geral')
  end
end
