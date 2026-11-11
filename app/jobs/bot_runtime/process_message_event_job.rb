# frozen_string_literal: true

module BotRuntime
  class ProcessMessageEventJob < ApplicationJob
    queue_as :bot_runtime
    retry_on StandardError, wait: :polynomially_longer, attempts: 8

    def perform(event_id)
      return unless Config.enabled?

      journal = MessageEvent.find_by(id: event_id)
      process_journal(journal) if journal
    rescue StandardError
      schedule_retry(journal) if journal
      raise
    end

    private

    def process_journal(journal)
      journal.with_lock do
        next if journal.processed_at

        journal.update!(attempts: journal.attempts + 1)
        dispatch(journal) unless already_handled?(journal)
        journal.update!(processed_at: Time.current)
      end
    end

    def already_handled?(journal)
      # Moderation enabled after capture must never replay moderation side effects.
      journal.message.inbox.agent_bot_inbox&.moderation_enabled? || Delivery.exists?(message_id: journal.message_id)
    end

    def dispatch(journal)
      # Re-evaluate channel and conversation eligibility on every attempt.
      event = Events::Base.new('message.created', journal.created_at,
                               message: journal.message, runtime_journal_replay: true)
      AgentBotListener.instance.message_created(event)
    end

    def schedule_retry(journal)
      # Rotate failed work after the listener transaction has rolled back.
      journal.with_lock do
        next if journal.processed_at

        attempts = journal.attempts + 1
        delay = [2**[attempts, 10].min, 600].min.seconds
        journal.update!(attempts: attempts, next_attempt_at: delay.from_now)
      end
    end
  end
end
