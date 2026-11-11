# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::DeliverPendingEventJob, type: :job do
  subject(:job) { described_class.new }

  let(:delivery) do
    instance_double(BotRuntime::Delivery, id: 'delivery-1', delivered_at: nil,
                                          next_attempt_at: 1.minute.ago, attempts: 0,
                                          agent_bot_id: 'bot-1', message_content: '20/11 a 23/11', message: message,
                                          agent_bot: bot, lease_token: 'lease-1', skipped_at: nil)
  end
  let(:message) { instance_double(Message, conversation: conversation) }
  let(:conversation) { instance_double(Conversation, inbox: inbox, post_conversation?: false) }
  let(:inbox) { instance_double(Inbox, agent_bot_inbox: assignment) }
  let(:assignment) { instance_double(AgentBotInbox, active?: true, agent_bot_id: 'bot-1', processing_block_reason: nil) }
  let(:bot) { instance_double(AgentBot) }
  let(:builder) { instance_double(BotRuntime::DelegationService, build_message_event: { message_content: 'changed' }) }
  let(:client) { instance_double(BotRuntime::Client) }
  let(:result) do
    BotRuntime::TranscriptionEnricher::Result.new(event: { message_content: '20/11 a 23/11' },
                                                  fallback_reasons: [], in_progress: false, forward_to_agent: true)
  end

  before do
    allow(SecureRandom).to receive(:uuid).and_return('lease-1')
    allow(BotRuntime::Config).to receive(:enabled?).and_return(true)
    allow(BotRuntime::Delivery).to receive(:find_by).with(id: 'delivery-1').and_return(delivery)
    allow(delivery).to receive(:with_lock).and_yield
    allow(delivery).to receive(:update!)
    allow(BotRuntime::DelegationService).to receive(:new).with(bot, message, conversation).and_return(builder)
    allow(BotRuntime::TranscriptionEnricher).to receive(:enrich)
      .with({ message_content: '20/11 a 23/11' }, in_progress_fallback: false).and_return(result)
    allow(BotRuntime::Client).to receive(:new).and_return(client)
  end

  it 'reconstructs the event while preserving the original text and acknowledges only successful delivery' do
    expect(client).to receive(:send_event).with(result.event)
    expect(delivery).to receive(:update!).with(delivered_at: anything, last_error: nil, lease_token: nil)
    job.perform('delivery-1')
  end

  it 'keeps a failed request pending for scheduled replay, including circuit-open failures' do
    allow(client).to receive(:send_event).and_raise(BotRuntime::CircuitBreaker::CircuitOpenError)
    expect(delivery).not_to receive(:update!).with(hash_including(:delivered_at))
    expect(delivery).to receive(:update!).with(next_attempt_at: anything, last_error: 'BotRuntime::CircuitBreaker::CircuitOpenError',
                                               lease_token: nil)
    job.perform('delivery-1')
  end

  it 'does not send an already acknowledged delivery again' do
    allow(delivery).to receive(:delivered_at).and_return(Time.current)
    expect(client).not_to receive(:send_event)
    job.perform('delivery-1')
  end

  it 'keeps audio contention pending without acknowledging it' do
    result.in_progress = true
    scheduled = instance_double(ActiveJob::ConfiguredJob, perform_later: nil)
    allow(described_class).to receive(:set).with(wait: 5.seconds).and_return(scheduled)
    expect(client).not_to receive(:send_event)
    expect(delivery).not_to receive(:update!).with(hash_including(:delivered_at))
    job.perform('delivery-1')
  end

  it 'retains audio fallback failures for retry' do
    result.forward_to_agent = false
    result.fallback_reasons = [:unavailable]
    allow(BotRuntime::AudioFallbackService).to receive(:deliver).and_return(false)
    expect(delivery).not_to receive(:update!).with(hash_including(:delivered_at))
    expect(delivery).to receive(:update!).with(next_attempt_at: anything, last_error: 'RuntimeError', lease_token: nil)
    job.perform('delivery-1')
  end

  it 'does not acknowledge an expired attempt after another worker took its lease' do
    allow(delivery).to receive(:lease_token).and_return('newer-lease')
    allow(client).to receive(:send_event)
    expect(delivery).not_to receive(:update!).with(hash_including(:delivered_at))
    job.perform('delivery-1')
  end

  it 'records a terminal skip when conversation eligibility changes during an outage' do
    allow(assignment).to receive(:agent_bot_id).and_return('another-bot')
    expect(client).not_to receive(:send_event)
    expect(delivery).to receive(:update!).with(skipped_at: anything, skipped_reason: 'bot_assignment_changed', lease_token: nil)
    job.perform('delivery-1')
  end
end
