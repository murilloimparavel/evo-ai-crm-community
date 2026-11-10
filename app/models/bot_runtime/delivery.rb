# frozen_string_literal: true

module BotRuntime
  class Delivery < ApplicationRecord
    self.table_name = 'bot_runtime_deliveries'
    belongs_to :message
    belongs_to :agent_bot
    scope :due, -> { where(delivered_at: nil, skipped_at: nil).where('next_attempt_at <= ?', Time.current) }
  end
end
