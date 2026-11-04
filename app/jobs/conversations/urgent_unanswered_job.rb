class Conversations::UrgentUnansweredJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    due = Conversation.live.where(status: %i[open pending])
                      .where('last_activity_at >= ?', 2.days.ago)
                      .where('waiting_since <= ?', 2.minutes.ago)
    flagged = Conversation.where("custom_attributes->>'urgent_followup' = 'true'")
    due.or(flagged).find_each(batch_size: 100) do |conversation|
      Conversations::UrgentUnansweredService.new(conversation).process
    end
  end
end
