class CreatePipelineClassificationEvents < ActiveRecord::Migration[7.1]
  def change
    # Durable receipt identity prevents delayed/replayed equal-clock incoming
    # events from reopening an already observed paid classification generation.
    create_table :pipeline_classification_events, id: :uuid do |t|
      t.references :pipeline, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :conversation, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.uuid :message_id, null: false
      t.datetime :created_at, null: false
    end
    add_index :pipeline_classification_events, [:pipeline_id, :conversation_id, :message_id], unique: true, name: 'idx_pipeline_incoming_receipt'
  end
end
