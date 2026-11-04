class FollowupBudgetDay < ApplicationRecord
  has_many :followup_budget_reservations, dependent: :restrict_with_exception
end
