class AddPipelineClassificationEventOrder < ActiveRecord::Migration[7.1]
  def change
    # Zero denotes a receipt accepted before explicit ordering was introduced;
    # ambiguous ties involving such receipts are rejected by the snapshot builder.
    add_column :pipeline_classification_events, :accepted_generation, :bigint, null: false, default: 0
  end
end
