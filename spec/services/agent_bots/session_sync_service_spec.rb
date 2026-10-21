# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBots::SessionSyncService do
  let(:conversation) { double('Conversation', inbox: double('Inbox'), contact_id: 'contact-1') }
  let(:service) { described_class.new(conversation) }
  let(:message) do
    double(
      'Message', incoming?: false, sender_type: 'User', id: 'message-1',
      content: 'Resposta do atendente', created_at: Time.zone.parse('2026-10-21 12:00:00')
    )
  end

  before do
    allow(service).to receive(:should_sync?).and_return(true)
    allow(service).to receive(:extract_agent_id).and_return('agent-1')
    allow(service).to receive(:build_session_id).and_return('session-1')
  end

  it 'sends human agent messages with distinct authorship and a stable idempotency key' do
    response = double('HTTP response', code: '201')
    expect(service).to receive(:make_request).with(
      :post,
      '/api/v1/sessions/session-1/events',
      hash_including(
        author: 'human_agent',
        role: 'model',
        content: '[Mensagem do atendente humano] Resposta do atendente',
        invocation_id: 'crm-message-message-1'
      )
    ).and_return(response)

    expect(service.add_message_event(message)).to be(true)
  end

  it 'keeps incoming messages in the user role without the human-agent prefix' do
    incoming = double(
      'Message', incoming?: true, sender_type: 'Contact', id: 'message-2',
      content: 'Preciso de ajuda', created_at: Time.zone.parse('2026-10-21 12:01:00')
    )
    response = double('HTTP response', code: '201')
    expect(service).to receive(:make_request).with(
      :post,
      '/api/v1/sessions/session-1/events',
      hash_including(author: 'user', role: 'user', content: 'Preciso de ajuda', invocation_id: 'crm-message-message-2')
    ).and_return(response)

    expect(service.add_message_event(incoming)).to be(true)
  end

  it 'uses bounded, configurable HTTP timeouts' do
    expect(service.send(:timeout_setting, 'MISSING_TIMEOUT', 2, max: 10)).to eq(2)

    previous = ENV['EVO_AI_PROCESSOR_READ_TIMEOUT_SECONDS']
    ENV['EVO_AI_PROCESSOR_READ_TIMEOUT_SECONDS'] = '999'
    expect(service.send(:timeout_setting, 'EVO_AI_PROCESSOR_READ_TIMEOUT_SECONDS', 5, max: 30)).to eq(30)
  ensure
    previous.nil? ? ENV.delete('EVO_AI_PROCESSOR_READ_TIMEOUT_SECONDS') : ENV['EVO_AI_PROCESSOR_READ_TIMEOUT_SECONDS'] = previous
  end
end
