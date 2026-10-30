module Followups
  class ReconcileJob < ApplicationJob
    queue_as :scheduled_jobs

    # Recover only the existing fenced states without resending requests whose provider outcome is unknown.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    def perform
      now = Time.current
      Retention.retire_orphans!(now: now)
      FollowupExecution.where(status: 'dispatching').where('lease_expires_at <= ?', now).limit(100).find_each do |execution|
        # The process could have died after provider acceptance. Never resend.
        FollowupExecution.where(id: execution.id, status: 'dispatching', fence_token: execution.fence_token)
                         # Keep this lifecycle-only SQL update atomic; callbacks must not reopen cancelled or fenced work.
                         # rubocop:disable Rails/SkipsModelValidations
                         .update_all(status: 'delivery_unknown', reason: 'dispatch_lease_lost', lease_expires_at: nil, updated_at: now)
        # rubocop:enable Rails/SkipsModelValidations
      end
      FollowupExecution.where(status: 'queued').where('next_attempt_at IS NULL OR next_attempt_at <= ?', now).limit(100).find_each do |execution|
        next unless execution.message_id

        message = Message.find_by(id: execution.message_id, followup_execution_id: execution.id)
        next unless message

        if message.source_id.present?
          DeliveryTracker.status_changed(message: message, status: message.status, provider_id: message.source_id, now: now)
        elsif execution.expires_at <= now
          FollowupExecution.where(id: execution.id, status: 'queued', fence_token: execution.fence_token)
                           # Keep this lifecycle-only SQL update atomic; callbacks must not reopen cancelled or fenced work.
                           # rubocop:disable Rails/SkipsModelValidations
                           .update_all(status: 'cancelled', reason: 'authorization_expired', finalized_at: now, updated_at: now)
        # rubocop:enable Rails/SkipsModelValidations
        else
          # The shared SendReplyJob CAS makes duplicate enqueues harmless.
          SendReplyJob.perform_later(message.id)
        end
      end
      FollowupExecution.where(status: 'ready').limit(100).find_each do |execution|
        QueueService.new(execution: execution, fence_token: execution.fence_token, now: now).call
      end
      FollowupExecution.where(status: 'evaluating').where('lease_expires_at <= ?', now).limit(100).find_each do |execution|
        EvaluateJob.perform_later(execution.id)
      end
      FollowupClassification.where(status: 'evaluating').where('lease_expires_at <= ?', now).limit(100).find_each do |classification|
        ClassificationRetryJob.perform_later(classification.id)
      end
      FollowupExecution.where(status: 'delivery_unknown').where.not(message_id: nil).limit(100).find_each do |execution|
        message = Message.find_by(id: execution.message_id)
        next if message&.source_id.blank?

        DeliveryTracker.status_changed(message: message, status: message.status, provider_id: message.source_id, now: now)
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
  end
end
