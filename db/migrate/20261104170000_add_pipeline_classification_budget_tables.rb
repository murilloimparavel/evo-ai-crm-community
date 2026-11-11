class AddPipelineClassificationBudgetTables < ActiveRecord::Migration[7.1]
  def change # rubocop:disable Metrics/MethodLength
    create_table :pipeline_classification_budget_days, id: :uuid do |t|
      t.string :scope_key, null: false
      t.date :budget_date, null: false
      t.string :timezone, null: false
      t.decimal :reserved_usd, precision: 16, scale: 8, null: false, default: 0
      t.decimal :spent_usd, precision: 16, scale: 8, null: false, default: 0
      t.jsonb :conversation_ids, null: false, default: []
      t.integer :conversation_count, null: false, default: 0
      t.timestamps
    end
    add_index :pipeline_classification_budget_days, [:scope_key, :budget_date], unique: true,
                                                                                name: 'idx_pipeline_classification_budget_day'
    add_index :pipeline_classification_budget_days, :budget_date

    create_table :pipeline_classification_budget_reservations, id: :uuid do |t|
      t.references :pipeline_classification_budget_day, type: :uuid, null: false,
                                                        foreign_key: { on_delete: :restrict }
      t.references :pipeline_classification_result, type: :uuid, null: false,
                                                    foreign_key: { on_delete: :cascade }
      t.integer :attempt_number, null: false
      t.decimal :reserved_usd, precision: 16, scale: 8, null: false
      t.decimal :actual_usd, precision: 16, scale: 8
      t.integer :input_tokens
      t.string :status, null: false, default: 'reserved'
      t.timestamps
    end
    add_index :pipeline_classification_budget_reservations,
              [:pipeline_classification_result_id, :attempt_number], unique: true,
                                                                     name: 'idx_pipeline_classification_reservation_attempt'
  end
end
