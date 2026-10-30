module Followups
  class DebouncedClassificationJob < ApplicationJob
    queue_as :scheduled_jobs

    def perform(conversation_id, generation)
      conversation = Conversation.find_by(id: conversation_id)
      DebouncedClassifier.new(conversation: conversation, generation: generation).call if conversation
    end
  end
end
