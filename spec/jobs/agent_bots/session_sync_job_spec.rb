# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBots::SessionSyncJob do
  let(:message) { instance_double(Message, id: 'message-1') }

  it 'uses the low queue and a bounded retry count' do
    expect(described_class.get_sidekiq_options['queue']).to eq(:low)
    expect(described_class.get_sidekiq_options['retry']).to eq(4)
  end

  it 'synchronizes a message when the rate limit allows it' do
    allow(Message).to receive(:find_by).with(id: message.id).and_return(message)
    allow(AgentBots::SessionSyncRateLimiter).to receive(:acquire_delay).and_return(0)
    allow(AgentBots::SessionSyncService).to receive(:add_event_for_message).with(message).and_return(true)

    described_class.new.perform(message.id)

    expect(AgentBots::SessionSyncService).to have_received(:add_event_for_message).with(message)
  end

  it 'defers a message when the shared rate limit is exhausted' do
    allow(Message).to receive(:find_by).with(id: message.id).and_return(message)
    allow(AgentBots::SessionSyncRateLimiter).to receive(:acquire_delay).and_return(2)
    expect(described_class).to receive(:perform_in).with(a_value >= 2, message.id)
    expect(AgentBots::SessionSyncService).not_to receive(:add_event_for_message)

    described_class.new.perform(message.id)
  end

  it 'raises on a failed delivery so Sidekiq applies the bounded retry policy' do
    allow(Message).to receive(:find_by).with(id: message.id).and_return(message)
    allow(AgentBots::SessionSyncRateLimiter).to receive(:acquire_delay).and_return(0)
    allow(AgentBots::SessionSyncService).to receive(:add_event_for_message).with(message).and_return(false)

    expect { described_class.new.perform(message.id) }.to raise_error(/Session sync failed/)
  end

  it 'does nothing if the source message was deleted before the job runs' do
    allow(Message).to receive(:find_by).with(id: message.id).and_return(nil)
    expect(AgentBots::SessionSyncRateLimiter).not_to receive(:acquire_delay)

    described_class.new.perform(message.id)
  end
end
