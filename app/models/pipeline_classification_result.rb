class PipelineClassificationResult < ApplicationRecord
  belongs_to :pipeline, optional: true
  belongs_to :conversation, optional: true
  belongs_to :pipeline_classification_catalog, optional: true
  validates :status, inclusion: { in: %w[reserved evaluating retryable_error classified abstained blocked cancelled] }
  validates :generation, :revision, :catalog_hash, :model, :question_version, presence: true

  after_update_commit :enqueue_auto_application, if: -> { saved_change_to_status? && status == 'classified' && reason == 'stage_recommended' }

  private

  def enqueue_auto_application
    PipelineClassification::ApplyDecisionJob.perform_later(id)
  end
end
