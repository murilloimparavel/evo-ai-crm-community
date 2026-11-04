class FollowupConversationState < ApplicationRecord
  belongs_to :conversation

  def self.for!(conversation)
    create_or_find_by!(conversation_id: conversation.id)
  end
end
