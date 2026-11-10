class CreateKnowledgeEntries < ActiveRecord::Migration[7.1]
  def change
    create_table :knowledge_entries, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.string :title, null: false
      t.text :body, null: false
      t.string :content_type, null: false
      t.string :source
      t.text :tags, array: true, null: false, default: []
      t.string :status, null: false, default: 'draft'
      t.string :account_scope, null: false
      t.uuid :created_by_id
      t.uuid :updated_by_id
      t.datetime :published_at
      t.timestamps
    end
    add_index :knowledge_entries, :status
    add_index :knowledge_entries, :account_scope
    add_index :knowledge_entries, :tags, using: :gin
    add_index :knowledge_entries, "to_tsvector('portuguese', coalesce(title, '') || ' ' || coalesce(body, ''))",
              using: :gin, name: 'index_knowledge_entries_on_portuguese_text'
  end
end
