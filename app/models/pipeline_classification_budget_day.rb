class PipelineClassificationBudgetDay < ApplicationRecord
  has_many :pipeline_classification_budget_reservations, dependent: :restrict_with_exception

  validates :scope_key, :budget_date, :timezone, presence: true
  validates :reserved_usd, :spent_usd, numericality: { greater_than_or_equal_to: 0 }
end
