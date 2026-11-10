require 'rails_helper'

RSpec.describe Notification::PushNotificationService do
  let(:conversation) { double(display_id: 123) }
  let(:notification) do
    double(conversation: conversation, push_message_title: 'Conversa #123', push_message_body: 'Ana: Olá',
           notification_type: 'assigned_conversation_new_message', id: 'notification-id')
  end
  subject(:service) { described_class.new(notification: notification) }

  it 'includes the sender and preview and links to the Sofia conversation' do
    payload = service.send(:push_message)
    expect(payload[:body]).to eq('Ana: Olá')
    expect(payload[:url]).to eq('/conversations/123')
  end

  it 'requires an appropriate VAPID subject instead of using an empty frontend URL' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('VAPID_SUBJECT').and_return('')
    allow(ENV).to receive(:[]).with('FRONTEND_URL').and_return('')
    expect { service.send(:vapid_subject) }.to raise_error(ArgumentError, /VAPID_SUBJECT/)
    allow(ENV).to receive(:[]).with('FRONTEND_URL').and_return('https://crm.example')
    expect(service.send(:vapid_subject)).to eq('https://crm.example')
  end
end
