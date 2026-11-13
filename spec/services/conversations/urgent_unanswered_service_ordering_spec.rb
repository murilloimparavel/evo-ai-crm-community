# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::UrgentUnansweredService do
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'Ordering test inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Ordering customer', email: "ordering-#{SecureRandom.hex(4)}@example.com") }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:bot) do
    AgentBot.create!(name: 'Ordering test bot', bot_provider: 'evo_ai', api_key: 'synthetic-test-key',
                     outgoing_url: 'https://example.test/bot')
  end
  let(:bot_inbox) { AgentBotInbox.create!(agent_bot: bot, inbox: inbox, status: :active) }
  let(:older_incoming) { insert_message('incoming', 3.days.ago, 'Old customer question') }
  let(:older_reply) { insert_message('outgoing', 2.days.ago, 'Old reply') }
  let(:latest_incoming) { insert_message('incoming', 3.minutes.ago, 'Latest customer question') }
  let(:http_client) { instance_double(AgentBots::HttpRequestService, perform: nil) }
  let(:cadence) { AgentBots::InactivityActionsService.new(conversation, bot) }
  let(:payload) do
    {
      conversation: { id: conversation.id },
      inactivity_metadata: { execution_id: SecureRandom.uuid, source_incoming_message_id: latest_incoming.id, urgent_followup: true }
    }
  end

  before do
    allow(AgentBots::HttpRequestService).to receive(:new).and_return(http_client)
    bot_inbox
    older_incoming
    older_reply
    latest_incoming
  end

  def insert_message(type, at, content, id: SecureRandom.uuid)
    attributes = { id: id, inbox_id: inbox.id, conversation_id: conversation.id, private: false,
                   message_type: Message.message_types.fetch(type), content: content, created_at: at, updated_at: at }
    # Historical fixtures must not dispatch customer-facing callbacks.
    # rubocop:disable Rails/SkipsModelValidations
    Message.insert!(attributes)
    # rubocop:enable Rails/SkipsModelValidations
    Message.find(id)
  end

  def mark_latest
    conversation.update!(custom_attributes: { 'urgent_followup' => true, 'urgent_followup_message_id' => latest_incoming.id })
    cadence.instance_variable_set(:@urgent_followup, true)
  end

  it 'marks the latest unanswered message even when an older question already has a reply' do
    described_class.new(conversation).process

    expect(conversation.reload.custom_attributes['urgent_followup_message_id']).to eq(latest_incoming.id)
    expect(conversation.custom_attributes['urgent_followup_message_id']).not_to eq(older_incoming.id)
  end

  it 'waits for two minutes after a newer incoming message' do
    mark_latest
    insert_message('incoming', 90.seconds.ago, 'A newer question')

    described_class.new(conversation).process

    expect(conversation.reload.custom_attributes['urgent_followup']).not_to be(true)
    expect(http_client).not_to have_received(:perform)
  end

  it 'uses the message ID as a deterministic tie-breaker for equal timestamps' do
    at = 150.seconds.ago
    insert_message('incoming', at, 'First tied question', id: '00000000-0000-0000-0000-000000000001')
    latest = insert_message('incoming', at, 'Last tied question', id: 'ffffffff-ffff-ffff-ffff-ffffffffffff')

    described_class.new(conversation).process

    expect(conversation.reload.custom_attributes['urgent_followup_message_id']).to eq(latest.id)
  end

  it 'does not request an urgent follow-up across repeated passes' do
    2.times { described_class.new(conversation.reload).process }
    expect(http_client).not_to have_received(:perform)
    expect(InactivityActionExecution.where(conversation_id: conversation.id, action_index: -2)).to be_empty
  end

  it 'ignores an urgent job that was queued before retirement' do
    expect(Conversations::UrgentUnansweredService).not_to receive(:new)
    Conversations::UrgentUnansweredJob.new.perform
  end

  it 'validates the latest cycle instead of the first incoming message' do
    mark_latest

    expect(cadence.send(:current_for_followup_cycle?, latest_incoming)).to be(true)
    expect(cadence.send(:current_for_followup_cycle?, older_incoming)).to be(false)
    expect(AgentBots::MessageCreator.new(bot).send(:urgent_followup_allowed?, conversation)).to be(true)
  end

  it 'rejects an urgent response already in flight' do
    mark_latest
    processor = AgentBots::ResponseProcessor.new(bot, payload)
    expect(processor.send(:stale_inactivity_response?, conversation)).to be(true)
  end

  it 'does not create a public message for an urgent response in flight' do
    mark_latest
    processor = AgentBots::ResponseProcessor.new(bot, payload)
    response = { 'result' => { 'artifacts' => [{ 'parts' => [{ 'type' => 'text', 'text' => 'Synthetic urgent reply' }] }] } }
    expect { processor.send(:process_bot_response, response) }.not_to(change { conversation.messages.outgoing.count })
  end

  it 'keeps ignored labels blocking the bot while the conversation enters the urgent queue' do
    label = Label.create!(title: "human-only-#{SecureRandom.hex(4)}")
    bot_inbox.update!(ignored_label_ids: [label.id])
    conversation.update!(label_list: [label.title])

    described_class.new(conversation).process

    expect(conversation.reload.custom_attributes['urgent_followup_message_id']).to eq(latest_incoming.id)
    expect(http_client).not_to have_received(:perform)
    expect(InactivityActionExecution.where(conversation_id: conversation.id, action_index: -2)).to be_empty
  end

  it 'builds the most recent 25 public messages in chronological order' do
    30.times { |index| insert_message('incoming', 2.hours.ago + index.minutes, "Context #{index}") }
    cadence.instance_variable_set(:@urgent_followup, true)

    context = cadence.send(:recent_customer_facing_context)

    expect(context.lines.length).to eq(25)
    expect(context).not_to include(older_reply.content, 'Context 0')
    expect(context.index('Context 6')).to be < context.index('Context 29')
    expect(context.index('Context 29')).to be < context.index(latest_incoming.content)
  end
end
