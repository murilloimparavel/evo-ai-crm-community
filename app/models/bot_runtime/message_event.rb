# frozen_string_literal: true

module BotRuntime
  class MessageEvent < ApplicationRecord
    self.table_name = 'bot_runtime_message_events'
    belongs_to :message
    scope :due, -> { where(processed_at: nil).where('next_attempt_at <= ?', Time.current) }
  end
end
