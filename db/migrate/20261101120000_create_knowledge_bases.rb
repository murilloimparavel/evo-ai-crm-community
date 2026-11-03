class CreateKnowledgeBases < ActiveRecord::Migration[7.1]
  # The migration preserves existing entries and creates the account-scoped aggregate atomically.
  def up # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    create_table :knowledge_bases, id: :uuid do |t|
      t.string :account_scope, null: false
      t.string :name, null: false
      t.text :description
      t.string :status, null: false, default: 'active'
      t.boolean :legacy_default, null: false, default: false
      t.integer :lock_version, null: false, default: 0
      t.uuid :created_by_id
      t.uuid :updated_by_id
      t.timestamps
    end
    add_index :knowledge_bases, 'account_scope, lower(btrim(name))', unique: true, name: 'idx_knowledge_bases_scope_name'
    add_index :knowledge_bases, :account_scope, unique: true, where: 'legacy_default', name: 'idx_knowledge_default_per_scope'
    add_reference :knowledge_entries, :knowledge_base, type: :uuid, foreign_key: true
    execute <<~SQL.squish
      INSERT INTO knowledge_bases (id, account_scope, name, status, legacy_default, created_at, updated_at)
      SELECT gen_random_uuid(), account_scope, 'Geral', 'active', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM knowledge_entries GROUP BY account_scope
    SQL
    execute <<~SQL.squish
      UPDATE knowledge_entries e SET knowledge_base_id = b.id
      FROM knowledge_bases b WHERE e.account_scope = b.account_scope AND b.legacy_default = TRUE
    SQL
    create_table :knowledge_agent_access_profiles, id: :uuid do |t|
      t.string :account_scope, null: false
      t.uuid :external_agent_id, null: false
      t.bigint :revision, null: false, default: 0
      t.timestamps
    end
    add_index :knowledge_agent_access_profiles, [:account_scope, :external_agent_id], unique: true, name: 'idx_knowledge_agent_profile'
    create_table :knowledge_agent_bindings, id: :uuid do |t|
      t.string :account_scope, null: false
      t.uuid :external_agent_id, null: false
      t.references :knowledge_base, type: :uuid, null: false, foreign_key: true
      t.boolean :enabled, null: false, default: true
      t.uuid :created_by_id
      t.uuid :updated_by_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :knowledge_agent_bindings, [:account_scope, :external_agent_id, :knowledge_base_id], unique: true,
                                                                                                   name: 'idx_knowledge_agent_binding_unique'
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Knowledge bases and bindings may contain user content'
  end
end
