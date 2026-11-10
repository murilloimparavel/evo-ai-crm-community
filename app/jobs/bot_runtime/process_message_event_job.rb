# frozen_string_literal: true

module BotRuntime
  class ProcessMessageEventJob < ApplicationJob
    queue_as :bot_runtime
    retry_on StandardError, wait: :polynomially_longer, attempts: 8

    def perform(event_id)
      return unless Config.enabled?

      journal = MessageEvent.find_by(id: event_id)
      return unless journal

      journal.with_lock do
        return if journal.processed_at
        journal.update!(attempts: journal.attempts + 1)
        if journal.message.inbox.agent_bot_inbox&.moderation_enabled?
          # Configuration changed after capture: never replay newly enabled
          # moderation side effects through this non-moderated journal.
          journal.update!(processed_at: Time.current)
          return
        end
        if Delivery.exists?(message_id: journal.message_id)
          journal.update!(processed_at: Time.current)
          return
        end
        # Reuse channel and conversation eligibility rules. On a
        # retry these are evaluated again; no bypass based on stale eligibility.
        event = Events::Base.new('message.created', journal.created_at,
                                 message: journal.message, runtime_journal_replay: true)
        AgentBotListener.instance.message_created(event)
        journal.update!(processed_at: Time.current)
      end
    rescue StandardError
      if journal && !journal.processed_at
        # The listener transaction rolled back. Persist retry scheduling outside
        # that transaction so a failed evaluation rotates behind untouched work.
        journal.with_lock do
          unless journal.processed_at
            attempts = journal.attempts + 1
            delay = [2**[attempts, 10].min, 600].min.seconds
            journal.update!(attempts: attempts, next_attempt_at: delay.from_now)
          end
        end
      end
      raise
    end
  end
end
