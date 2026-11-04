# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBots::InactivityActionsService do
  subject(:service) { described_class.allocate }

  describe '#find_action_to_execute' do
    let(:actions) do
      [
        { 'minutes' => 10, 'action' => 'interact' },
        { 'minutes' => 180, 'action' => 'interact' },
        { 'minutes' => 1440, 'action' => 'interact' }
      ]
    end

    before do
      service.instance_variable_set(:@conversation, double(id: 'conversation-id'))
      allow(InactivityActionExecution).to receive(:last_action_index_for).and_return(-1)
    end

    it 'selects the latest due step when the scheduler missed earlier thresholds' do
      expect(service.send(:find_action_to_execute, actions, 200)).to eq(config: actions[1], index: 1)
    end

    it 'does not select a step before its threshold' do
      expect(service.send(:find_action_to_execute, actions, 9)).to be_nil
    end
  end

  describe '#should_process?' do
    let(:conversation) do
      double(open?: true, pending?: false, assignee_id: 'human-user-id', custom_attributes: {})
    end
    let(:inbox) { double(present?: true) }
    let(:agent_bot) do
      double(present?: true, bot_config: { 'inactivity_actions' => [{ 'minutes' => 10, 'action' => 'interact' }] })
    end

    before do
      service.instance_variable_set(:@conversation, conversation)
      service.instance_variable_set(:@inbox, inbox)
      service.instance_variable_set(:@agent_bot, agent_bot)
    end

    it 'skips conversations assigned to a human' do
      expect(service.send(:should_process?)).to be(false)
    end

    it 'keeps the configured cadence available for a marked webhook conversation' do
      allow(conversation).to receive(:assignee_id).and_return(nil)
      allow(conversation).to receive(:custom_attributes).and_return({ 'urgent_followup' => true })

      expect(service.send(:should_process?)).to be(true)
    end
  end

  describe '#reserve_execution' do
    let(:channel) { Channel::Api.create! }
    let(:inbox) { Inbox.create!(name: 'Cadence test inbox', channel: channel) }
    let(:contact) { Contact.create!(name: 'Cadence customer', email: "cadence-#{SecureRandom.hex(4)}@example.com") }
    let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
    let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
    let(:bot) { AgentBot.create!(name: 'Cadence bot', outgoing_url: 'https://example.test/bot') }
    let(:incoming) { instance_double(Message, id: SecureRandom.uuid) }
    let(:action) { { 'action' => 'interact', 'minutes' => 10 } }
    let(:cadence) { described_class.new(conversation, bot) }

    before { allow(cadence).to receive(:current_for_followup_cycle?).with(incoming).and_return(true) }

    it 'defers urgent automation while a normal step is pending' do
      normal = cadence.send(:reserve_execution, action, 0, 'interact', incoming)
      cadence.instance_variable_set(:@urgent_followup, true)

      expect(cadence.send(:reserve_execution, action, -2, 'interact', incoming)).to be_nil
      expect(normal.execution_status).to eq('pending')
    end

    it 'defers normal automation while urgent owns the cycle, then resumes after failure' do
      cadence.instance_variable_set(:@urgent_followup, true)
      urgent = cadence.send(:reserve_execution, action, -2, 'interact', incoming)
      cadence.instance_variable_set(:@urgent_followup, false)

      expect(cadence.send(:reserve_execution, action, 0, 'interact', incoming)).to be_nil

      urgent.update!(execution_status: 'failed')
      expect(cadence.send(:reserve_execution, action, 0, 'interact', incoming)).to be_present
    end
  end

  describe '#cycle_started_after_activation?' do
    let(:activation_time) { Time.zone.parse('2026-10-02 10:00:00') }
    let(:agent_bot) do
      double(id: 'bot-id', bot_config: { 'inactivity_actions_active_from' => activation_time.iso8601 })
    end

    before do
      service.instance_variable_set(:@agent_bot, agent_bot)
    end

    it 'skips an inactivity cycle that began before activation' do
      incoming = double(created_at: activation_time - 1.second)

      expect(service.send(:cycle_started_after_activation?, incoming)).to be(false)
    end

    it 'allows a new customer message at or after activation' do
      incoming = double(created_at: activation_time)

      expect(service.send(:cycle_started_after_activation?, incoming)).to be(true)
    end

    it 'preserves legacy behavior when no activation cutoff is configured' do
      allow(agent_bot).to receive(:bot_config).and_return({ 'inactivity_actions' => [] })
      incoming = double(created_at: activation_time - 1.second)

      expect(service.send(:cycle_started_after_activation?, incoming)).to be(true)
    end

    it 'fails closed when the activation timestamp is invalid' do
      allow(agent_bot).to receive(:bot_config).and_return({ 'inactivity_actions_active_from' => 'invalid' })
      incoming = double(created_at: activation_time)

      expect(service.send(:cycle_started_after_activation?, incoming)).to be(false)
    end
  end

  describe '#process_pending_execution' do
    let(:incoming) { double(id: 'customer-message-id') }
    let(:execution) { double(source_incoming_message_id: incoming.id, id: 'execution-id') }

    it 'marks an already-created outgoing message as sent instead of retrying it' do
      sent_message = double(content: 'Retomando nosso atendimento')
      allow(service).to receive(:current_for_followup_cycle?).with(incoming).and_return(true)
      allow(service).to receive(:message_for_execution).with(execution).and_return(sent_message)
      expect(service).to receive(:record_execution).with(execution, sent_message.content)

      expect(service.send(:process_pending_execution, execution, incoming)).to eq(:handled)
    end

    it 'discards a reservation from an older customer-message cycle' do
      stale_execution = double(source_incoming_message_id: 'previous-message-id')
      expect(stale_execution).to receive(:destroy!)

      expect(service.send(:process_pending_execution, stale_execution, incoming)).to eq(:continue)
    end
  end
end
