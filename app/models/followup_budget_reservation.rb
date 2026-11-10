class FollowupBudgetReservation < ApplicationRecord
  belongs_to :followup_budget_day
  belongs_to :subject, polymorphic: true
end
