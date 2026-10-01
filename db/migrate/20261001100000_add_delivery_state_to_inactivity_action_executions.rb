class AddDeliveryStateToInactivityActionExecutions < ActiveRecord::Migration[7.1]
  def change
    add_column :inactivity_action_executions, :execution_status, :string, null: false, default: 'sent'
    add_column :inactivity_action_executions, :attempt_count, :integer, null: false, default: 0
    add_column :inactivity_action_executions, :source_incoming_message_id, :uuid

    add_index :inactivity_action_executions, :execution_status
  end
end
