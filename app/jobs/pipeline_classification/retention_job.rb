module PipelineClassification
  class RetentionJob < ApplicationJob
    queue_as :low
    TERMINAL_STATUSES = %w[classified abstained blocked cancelled].freeze
    BATCH_SIZE = 1000

    def perform
      days = Budget.settings['retention_days']
      return unless days.is_a?(Integer) && days.positive?

      cutoff = days.days.ago
      outstanding = PipelineClassificationBudgetReservation.where(status: 'reserved').select(:pipeline_classification_result_id)
      results = delete_in_batches(PipelineClassificationResult.where(status: TERMINAL_STATUSES).where('created_at < ?', cutoff)
                                                                        .where.not(id: outstanding))
      events = delete_in_batches(PipelineClassificationEvent.where('created_at < ?', cutoff))
      reserved_days = PipelineClassificationBudgetReservation.select(:pipeline_classification_budget_day_id)
      budget_days = delete_in_batches(PipelineClassificationBudgetDay.where('budget_date < ?', cutoff.to_date).where.not(id: reserved_days))
      Rails.logger.info("[PipelineClassification::RetentionJob] removed results=#{results} events=#{events} budget_days=#{budget_days}")
    end

    private

    def delete_in_batches(scope)
      deleted = 0
      loop do
        ids = scope.limit(BATCH_SIZE).pluck(:id)
        break if ids.empty?

        deleted += scope.where(id: ids).delete_all
      end
      deleted
    end
  end
end
