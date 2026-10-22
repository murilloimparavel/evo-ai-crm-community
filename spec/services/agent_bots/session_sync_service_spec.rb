# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBots::SessionSyncService do
  let(:conversation) do
    instance_double(Conversation, inbox: instance_double(Inbox, agent_bot: instance_double(AgentBot)), contact_id: 'contact-1')
  end
  let(:service) { described_class.new(conversation) }
  let(:message) do
    instance_double(
      Message,
      incoming?: false,
      sender_type: 'User',
      id: 'message-1',
      content: 'Resposta do atendente',
      created_at: Time.zone.parse('2026-10-21 12:00:00')
    )
  end

  before do
    allow(service).to receive(:should_sync?).and_return(true)
    allow(service).to receive(:extract_agent_id).and_return('agent-1')
    allow(service).to receive(:build_session_id).and_return('session-1')
  end

  it 'sends human agent messages with distinct authorship and a stable idempotency key' do
    response = instance_double(Net::HTTPResponse, code: '201')
    request = nil
    allow(service).to receive(:make_request) do |*args|
      request = args
      response
    end

    expect(service.add_message_event(message)).to be(true)
    expect(request).to include(:post, '/api/v1/sessions/session-1/events')
    expect(request[2]).to include(
      author: 'human_agent',
      role: 'model',
      content: '[Mensagem do atendente humano] Resposta do atendente',
      invocation_id: 'crm-message-message-1'
    )
  end

  it 'keeps incoming messages in the user role without the human-agent prefix' do
    incoming = instance_double(
      Message,
      incoming?: true,
      sender_type: 'Contact',
      id: 'message-2',
      content: 'Preciso de ajuda',
      created_at: Time.zone.parse('2026-10-21 12:01:00')
    )
    response = instance_double(Net::HTTPResponse, code: '201')
    request = nil
    allow(service).to receive(:make_request) do |*args|
      request = args
      response
    end

    expect(service.add_message_event(incoming)).to be(true)
    expect(request).to include(:post, '/api/v1/sessions/session-1/events')
    expect(request[2]).to include(
      author: 'user',
      role: 'user',
      content: 'Preciso de ajuda',
      invocation_id: 'crm-message-message-2'
    )
  end

  it 'uses bounded, configurable HTTP timeouts' do
    expect(service.send(:timeout_setting, 'MISSING_TIMEOUT', 2, max: 10)).to eq(2)

    previous = ENV.fetch('EVO_AI_PROCESSOR_READ_TIMEOUT_SECONDS', nil)
    ENV['EVO_AI_PROCESSOR_READ_TIMEOUT_SECONDS'] = '999'
    expect(service.send(:timeout_setting, 'EVO_AI_PROCESSOR_READ_TIMEOUT_SECONDS', 5, max: 30)).to eq(30)
  ensure
    previous.nil? ? ENV.delete('EVO_AI_PROCESSOR_READ_TIMEOUT_SECONDS') : ENV['EVO_AI_PROCESSOR_READ_TIMEOUT_SECONDS'] = previous
  end
end
