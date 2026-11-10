# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::ReplayPendingDeliveriesJob, type: :job do
  let(:contact) { Contact.create!(name: 'Replay fairness spec') }
  let(:inbox) { Inbox.create!(name: 'Replay fairness spec', channel: Channel::Api.create!) }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  it 'reaches the 501st journal even when the oldest 500 listener evaluations repeatedly fail' do
    now = Time.current
    messages = Array.new(501) { SecureRandom.uuid }
    Message.insert_all!(messages.map do |id|
      { id: id, inbox_id: inbox.id, conversation_id: conversation.id, message_type: 0,
        created_at: now, updated_at: now }
    end)
    journal_ids = Array.new(501) { SecureRandom.uuid }
    BotRuntime::MessageEvent.insert_all!(journal_ids.each_with_index.map do |id, index|
      timestamp = index < 500 ? 2.days.ago : 1.hour.ago
      { id: id, message_id: messages[index], created_at: timestamp, updated_at: timestamp, next_attempt_at: timestamp }
    end)
    queued = []
    allow(BotRuntime::ProcessMessageEventJob).to receive(:perform_later) { |id| queued << id }
    allow(BotRuntime::Config).to receive(:enabled?).and_return(true)
    allow(AgentBotListener.instance).to receive(:message_created).and_raise('poison listener event')

    described_class.new.perform
    expect(queued.size).to eq(500)
    expect(queued).not_to include(journal_ids.last)
    queued.each do |id|
      expect { BotRuntime::ProcessMessageEventJob.new.perform(id) }.to raise_error('poison listener event')
    end
    expect(BotRuntime::MessageEvent.where(id: queued, processed_at: nil).count).to eq(500)

    queued.clear
    described_class.new.perform
    expect(queued).to include(journal_ids.last)
  end

  it 'reserves a page before enqueue so lost worker delivery does not monopolize every sweep' do
    first = double(id: 'first')
    second = double(id: 'second')
    # The database-backed 501-record test covers ordering. This checks reservation
    # commits before any external enqueue failure can interrupt the sweep.
    relation = double('due relation')
    allow(BotRuntime::MessageEvent).to receive(:due).and_return(relation)
    allow(relation).to receive_message_chain(:order, :limit, :lock, :to_a).and_return([first, second])
    reserved = double('reserved relation')
    allow(BotRuntime::MessageEvent).to receive(:where).with(id: %w[first second]).and_return(reserved)
    expect(reserved).to receive(:update_all).with(next_attempt_at: anything).ordered
    expect(BotRuntime::ProcessMessageEventJob).to receive(:perform_later).with('first').ordered.and_raise('queue unavailable')
    expect { described_class.new.perform }.to raise_error('queue unavailable')
  end
end
