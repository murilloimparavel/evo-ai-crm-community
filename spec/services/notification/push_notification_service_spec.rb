require 'rails_helper'

RSpec.describe Notification::PushNotificationService do
  let(:conversation) { double(display_id: 123) }
  let(:notification) do
    double(conversation: conversation, push_message_title: 'Conversa #123', push_message_body: 'Ana: Olá',
           notification_type: 'assigned_conversation_new_message', id: 'notification-id')
  end
  subject(:service) { described_class.new(notification: notification) }

  it 'includes the sender and preview and links to the Sofia conversation' do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('FRONTEND_URL', 'http://localhost:3000').and_return('https://crm.example/')
    payload = service.send(:push_message)
    expect(payload[:body]).to eq('Ana: Olá')
    expect(payload[:url]).to eq('https://crm.example/conversations/123')
  end
end
