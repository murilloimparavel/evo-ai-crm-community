class CreatePipelineClassificationCatalogs < ActiveRecord::Migration[7.1]
  # Keep this reversible schema migration in one change method.
  def change # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    add_column :pipeline_stages, :classification_profile, :jsonb, null: false, default: {}
    create_table :pipeline_classification_catalogs, id: :uuid do |t|
      t.references :pipeline, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :catalog_version, null: false
      t.string :catalog_hash, null: false
      t.jsonb :snapshot, null: false
      t.references :approved_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :approved_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :pipeline_classification_catalogs, [:pipeline_id, :catalog_version], unique: true, name: 'idx_pipeline_catalog_revision'
    create_table :pipeline_classification_states, id: :uuid do |t|
      t.references :pipeline, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :conversation, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :generation, null: false, default: 0
      t.bigint :revision, null: false, default: 0
      t.uuid :source_incoming_message_id
      t.datetime :due_at
      t.string :context_digest
      t.timestamps
    end
    add_index :pipeline_classification_states, [:pipeline_id, :conversation_id], unique: true, name: 'idx_pipeline_classification_state_identity'
    add_index :pipeline_classification_states, :due_at
    create_table :pipeline_classification_results, id: :uuid do |t|
      t.references :pipeline, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :conversation, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :pipeline_classification_catalog, type: :uuid, foreign_key: { on_delete: :nullify }, index: { name: 'idx_pipeline_result_catalog' }
      t.uuid :source_incoming_message_id
      t.uuid :recommended_stage_id
      t.bigint :generation, null: false
      t.bigint :revision, null: false
      t.string :catalog_hash, null: false
      t.string :model, null: false
      t.string :question_version, null: false
      t.string :status, null: false, default: 'reserved'
      t.string :snapshot_hash
      t.string :reason
      t.jsonb :decision, null: false, default: {}
      t.integer :attempt_count, null: false, default: 0
      t.bigint :fence_token, null: false, default: 0
      t.datetime :lease_expires_at
      t.datetime :expires_at
      t.datetime :next_attempt_at
      t.bigint :input_tokens
      t.timestamps
    end
    add_index :pipeline_classification_results, [:pipeline_id, :conversation_id, :generation, :catalog_hash, :model, :question_version],
              unique: true, name: 'idx_pipeline_classification_cycle'
    add_index :pipeline_classification_results, [:status, :next_attempt_at], name: 'idx_pipeline_classification_retry'
  end
end
