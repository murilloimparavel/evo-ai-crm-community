class PipelineClassificationCatalog < ApplicationRecord
  belongs_to :pipeline
  belongs_to :approved_by, class_name: 'User', optional: true
  validates :catalog_version, :catalog_hash, :snapshot, :approved_at, presence: true
  validates :catalog_version, uniqueness: { scope: :pipeline_id }

  # Approved aggregates are append-only; pipeline deletion remains supported by FK.
  def readonly?
    persisted?
  end
end
