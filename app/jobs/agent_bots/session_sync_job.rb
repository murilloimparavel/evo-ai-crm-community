class AgentBots::SessionSyncJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 4

  sidekiq_retry_in do |count, _exception, _job, _options|
    # Four bounded retries after the initial attempt, with exponential backoff
    # and jitter to prevent a processor outage from causing a retry storm.
    base = [5 * (2**count), 300].min
    base + rand(0..[base / 4, 1].max)
  end

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return unless message

    wait_seconds = AgentBots::SessionSyncRateLimiter.acquire_delay
    if wait_seconds.positive?
      self.class.perform_in(wait_seconds + rand(0.0..1.0), message_id)
      return
    end

    result = AgentBots::SessionSyncService.add_event_for_message(message)
    raise "Session sync failed for CRM message #{message_id}" if result == false
  end
end
