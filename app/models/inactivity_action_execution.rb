# == Schema Information
#
# Table name: inactivity_action_executions
#
#  id              :uuid             not null, primary key
#  action_config   :jsonb
#  action_index    :integer          not null
#  action_type     :string
#  executed_at     :datetime         not null
#  message_sent    :text
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  agent_bot_id    :uuid             not null
#  conversation_id :uuid             not null
#
# Indexes
#
#  index_inactivity_action_executions_on_agent_bot_id     (agent_bot_id)
#  index_inactivity_action_executions_on_conversation_id  (conversation_id)
#  index_inactivity_action_executions_on_executed_at      (executed_at)
#  index_inactivity_executions_on_conv_and_action         (conversation_id,action_index) UNIQUE
#
class InactivityActionExecution < ApplicationRecord
  STATUSES = %w[pending sent failed].freeze

  belongs_to :conversation
  belongs_to :agent_bot

  validates :action_index, presence: true, uniqueness: { scope: :conversation_id }
  validates :action_type, inclusion: { in: %w[interact finalize] }
  validates :executed_at, presence: true
  validates :execution_status, inclusion: { in: STATUSES }
  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :for_conversation, ->(conversation_id) { where(conversation_id: conversation_id) }
  scope :pending, -> { where(execution_status: 'pending') }
  scope :ordered, -> { order(action_index: :asc) }
  scope :recent, -> { order(executed_at: :desc) }

  # Get the highest action index executed for a conversation
  def self.last_action_index_for(conversation_id)
    for_conversation(conversation_id).where(execution_status: %w[sent failed]).maximum(:action_index) || -1
  end

  def self.pending_for_conversation(conversation_id)
    pending.for_conversation(conversation_id).order(:created_at)
  end

  # Check if a specific action was already executed
  def self.action_executed?(conversation_id, action_index)
    exists?(conversation_id: conversation_id, action_index: action_index, execution_status: 'sent')
  end

  # Reset all executions for a conversation (when customer responds)
  def self.reset_for_conversation(conversation_id)
    for_conversation(conversation_id).destroy_all
  end
end
