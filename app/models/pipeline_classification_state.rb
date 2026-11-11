class PipelineClassificationState < ApplicationRecord
  belongs_to :pipeline
  belongs_to :conversation
end
