# frozen_string_literal: true

module BotRuntime
  class ReplayPendingDeliveriesJob < ApplicationJob
    queue_as :scheduled_jobs

    def perform
      # Reserve a fair page before enqueue. Even a poisoned page or lost enqueue
      # cannot monopolize the oldest-created page on every sweep.
      ids = MessageEvent.transaction do
        events = MessageEvent.due.order(:next_attempt_at, :id).limit(500).lock('FOR UPDATE SKIP LOCKED').to_a
        # Atomic reservation must avoid per-record callbacks under the page lock.
        MessageEvent.where(id: events.map(&:id)).update_all(next_attempt_at: 5.minutes.from_now) # rubocop:disable Rails/SkipsModelValidations
        events.map(&:id)
      end
      ids.each do |id|
        ProcessMessageEventJob.perform_later(id)
      end
      Delivery.due.order(:next_attempt_at).limit(500).pluck(:id).each do |id|
        DeliverPendingEventJob.perform_later(id)
      end
    end
  end
end
