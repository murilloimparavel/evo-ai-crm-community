class LinkFollowupPipelineClassifications < ActiveRecord::Migration[7.1]
  def change
    add_reference :followup_executions, :pipeline_classification_result, type: :uuid,
                                                                         foreign_key: { on_delete: :nullify },
                                                                         index: { name: 'index_followup_execution_pipeline_classification' }
    add_column :followup_executions, :classification_catalog_hash, :string
  end
end
