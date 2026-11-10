class AddRetryScheduleToBotRuntimeMessageEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :bot_runtime_message_events, :next_attempt_at, :datetime, null: false, default: -> { 'CURRENT_TIMESTAMP' }
    add_column :bot_runtime_message_events, :attempts, :integer, null: false, default: 0
    add_index :bot_runtime_message_events, [:next_attempt_at, :id],
              where: 'processed_at IS NULL', name: 'index_pending_runtime_message_event_retries'
  end
end
