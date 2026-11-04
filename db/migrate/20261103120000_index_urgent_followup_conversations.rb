class IndexUrgentFollowupConversations < ActiveRecord::Migration[7.1]
  def change
    add_index :conversations, :id,
              where: "custom_attributes->>'urgent_followup' = 'true'",
              name: 'index_conversations_urgent_followup'
  end
end
