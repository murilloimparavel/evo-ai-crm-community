class CreateKnowledgeResponseProvenances < ActiveRecord::Migration[7.1]
  def change
    create_table :knowledge_response_provenances, id: :uuid do |t|
      t.references :message, type: :uuid, null: true, foreign_key: { on_delete: :nullify }, index: { unique: true }
      t.boolean :reusable, null: false, default: false
      t.string :proof_jti, null: false
      t.string :account_scope, null: false
      t.string :executor_id, null: false
      t.string :config_sha256, null: false
      t.string :body_sha256, null: false
      t.integer :profile_revision, null: false, default: 0
      t.jsonb :tool_categories, null: false, default: []
      t.jsonb :sources, null: false, default: []
      t.timestamps
    end
    add_index :knowledge_response_provenances, :proof_jti, unique: true
  end
end
