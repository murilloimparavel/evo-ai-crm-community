class AddActivityEventIdToMessages < ActiveRecord::Migration[7.1]
  def change
    add_column :messages, :activity_event_id, :uuid
    add_index :messages, :activity_event_id,
              unique: true,
              where: 'activity_event_id IS NOT NULL',
              name: 'idx_messages_activity_event_id_unique'
  end
end
