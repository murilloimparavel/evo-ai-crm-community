require 'rails_helper'

RSpec.describe Conversations::UrgentUnansweredService do
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'Urgent test inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Customer', email: "urgent-#{SecureRandom.hex(4)}@example.com") }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  def insert_message(type, at)
    # Insert historical timestamps without dispatching customer-facing callbacks.
    # rubocop:disable Rails/SkipsModelValidations
    attributes = {
      id: SecureRandom.uuid,
      inbox_id: inbox.id,
      conversation_id: conversation.id,
      message_type: Message.message_types.fetch(type),
      content: 'Message',
      created_at: at,
      updated_at: at
    }
    Message.insert!(attributes)
    # rubocop:enable Rails/SkipsModelValidations
  end

  it 'marks a two-minute-old unanswered conversation urgent' do
    at = 3.minutes.ago
    insert_message('incoming', at)

    described_class.new(conversation).process

    expect(conversation.reload.custom_attributes['urgent_followup']).to be(true)
  end

  it 'waits for two full minutes before adding the conversation' do
    insert_message('incoming', 90.seconds.ago)

    described_class.new(conversation).process

    expect(conversation.reload.custom_attributes['urgent_followup']).not_to be(true)
  end

  it 'ignores conversations whose last customer message is older than two days' do
    insert_message('incoming', 3.days.ago)

    described_class.new(conversation).process

    expect(conversation.reload.custom_attributes['urgent_followup']).not_to be(true)
  end

  it 'does not mark a conversation that already has a public reply' do
    at = 3.minutes.ago
    insert_message('incoming', at)
    insert_message('outgoing', at + 1.minute)

    described_class.new(conversation).process

    expect(conversation.reload.custom_attributes['urgent_followup']).not_to be(true)
  end

  it 'removes the urgent marker when someone replies' do
    at = 3.minutes.ago
    insert_message('incoming', at)
    described_class.new(conversation).process
    insert_message('outgoing', at + 1.minute)

    described_class.new(conversation.reload).process

    expect(conversation.reload.custom_attributes['urgent_followup']).not_to be(true)
  end

  it 'keeps a recent unanswered conversation in the queue without contacting the bot after 24 hours' do
    at = 25.hours.ago
    insert_message('incoming', at)
    bot = instance_double(AgentBot, evo_ai_provider?: true)
    bot_inbox = instance_double(AgentBotInbox, active?: true, agent_bot: bot)
    allow(inbox).to receive(:agent_bot_inbox).and_return(bot_inbox)
    allow(conversation).to receive(:inbox).and_return(inbox)
    expect(AgentBots::InactivityActionsService).not_to receive(:new)

    described_class.new(conversation).process

    expect(conversation.reload.custom_attributes['urgent_followup']).to be(true)
  end
end
