class PipelineClassificationBudgetReservation < ApplicationRecord
  belongs_to :pipeline_classification_budget_day
  belongs_to :pipeline_classification_result

  validates :attempt_number, numericality: { only_integer: true, greater_than: 0 }
  validates :reserved_usd, numericality: { greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: %w[reserved settled released] }
end
