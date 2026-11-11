class CreateBotRuntimeDeliveries < ActiveRecord::Migration[7.1]
  def change
    create_message_events
    create_deliveries
  end

  private

  def create_message_events
    create_table :bot_runtime_message_events, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.uuid :message_id, null: false
      t.datetime :processed_at
      t.timestamps
    end
    add_foreign_key :bot_runtime_message_events, :messages, on_delete: :cascade
    add_index :bot_runtime_message_events, :message_id, unique: true
    add_index :bot_runtime_message_events, :created_at, where: 'processed_at IS NULL'
  end

  # Keep the delivery table and its indexes together for schema review.
  def create_deliveries
    create_table :bot_runtime_deliveries, id: :uuid, default: -> { 'gen_random_uuid()' } do |t|
      t.uuid :message_id, null: false
      t.uuid :agent_bot_id, null: false
      t.text :message_content, null: false, default: ''
      t.string :lease_token
      t.datetime :skipped_at
      t.string :skipped_reason
      t.datetime :delivered_at
      t.datetime :next_attempt_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }
      t.integer :attempts, null: false, default: 0
      t.string :last_error
      t.timestamps
    end
    add_foreign_key :bot_runtime_deliveries, :messages, on_delete: :cascade
    add_foreign_key :bot_runtime_deliveries, :agent_bots, on_delete: :cascade
    add_index :bot_runtime_deliveries, [:message_id, :agent_bot_id], unique: true
    add_index :bot_runtime_deliveries, :next_attempt_at,
              where: 'delivered_at IS NULL AND skipped_at IS NULL', name: 'index_pending_bot_runtime_deliveries'
  end
end
