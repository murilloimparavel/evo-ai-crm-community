class Conversations::UrgentUnansweredJob < ApplicationJob
  queue_as :scheduled_jobs

  # Existing scheduled or queued jobs must not reactivate the retired feature.
  def perform
    nil
  end
end
