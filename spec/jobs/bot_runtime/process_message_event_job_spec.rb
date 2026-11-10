# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::ProcessMessageEventJob, type: :job do
  let(:message) { instance_double(Message, id: 'message-1', inbox: inbox) }
  let(:inbox) { instance_double(Inbox, agent_bot_inbox: nil) }
  let(:journal) do
    instance_double(BotRuntime::MessageEvent, processed_at: nil, message_id: 'message-1', message: message, created_at: Time.current, attempts: 0)
  end

  before do
    allow(BotRuntime::Config).to receive(:enabled?).and_return(true)
    allow(BotRuntime::MessageEvent).to receive(:find_by).with(id: 'journal-1').and_return(journal)
    allow(journal).to receive(:with_lock).and_yield
    allow(journal).to receive(:update!)
    allow(BotRuntime::Delivery).to receive(:exists?).with(message_id: 'message-1').and_return(false)
  end

  it 'reuses the real listener entrypoint and acknowledges only a successful evaluation' do
    expect(AgentBotListener.instance).to receive(:message_created) do |event|
      expect(event.data[:message]).to eq(message)
      expect(event.data[:runtime_journal_replay]).to be(true)
    end
    expect(journal).to receive(:update!).with(processed_at: anything)
    described_class.new.perform('journal-1')
  end

  it 'leaves a failed evaluation unacknowledged for replay' do
    allow(AgentBotListener.instance).to receive(:message_created).and_raise('enqueue failed')
    expect(journal).not_to receive(:update!).with(hash_including(:processed_at))
    expect(journal).to receive(:update!).with(attempts: 1, next_attempt_at: anything)
    expect { described_class.new.perform('journal-1') }.to raise_error('enqueue failed')
  end

  it 'does not repeat listener side effects after delegation was already persisted' do
    allow(BotRuntime::Delivery).to receive(:exists?).with(message_id: 'message-1').and_return(true)
    expect(AgentBotListener.instance).not_to receive(:message_created)
    expect(journal).to receive(:update!).with(processed_at: anything)
    described_class.new.perform('journal-1')
  end

  it 'does not execute moderation enabled after the message was captured' do
    allow(inbox).to receive(:agent_bot_inbox).and_return(double(moderation_enabled?: true))
    expect(AgentBotListener.instance).not_to receive(:message_created)
    described_class.new.perform('journal-1')
  end
end
