require 'rails_helper'

RSpec.describe Notification::PushNotificationService do
  subject(:service) { described_class.new(notification: notification) }

  let(:conversation) { instance_double(Conversation, display_id: 123) }
  let(:notification) do
    instance_double(
      Notification, conversation: conversation, push_message_title: 'Conversa #123', push_message_body: 'Ana: Olá',
                    notification_type: 'assigned_conversation_new_message', id: 'notification-id'
    )
  end

  it 'includes the sender and preview and links to the Sofia conversation' do
    payload = service.send(:push_message)
    expect(payload[:body]).to eq('Ana: Olá')
    expect(payload[:url]).to eq('/conversations/123')
  end

  describe 'browser delivery' do
    let(:subscription) do
      instance_double(
        NotificationSubscription, id: 'subscription-id', browser_push?: true, valid?: true,
                                  subscription_attributes: { 'endpoint' => 'https://fcm.googleapis.com/test',
                                                             'p256dh' => 'public-key', 'auth' => 'auth-key' }
      )
    end

    before do
      allow(VapidService).to receive_messages(public_key: 'vapid-public', private_key: 'vapid-private',
                                              subject: 'https://crm.example')
      allow(WebPush).to receive(:payload_send)
    end

    it 'passes the encrypted delivery parameters and message details to WebPush' do
      service.send(:send_browser_push, subscription)
      expect(WebPush).to have_received(:payload_send) do |**payload|
        expect(payload[:endpoint]).to eq('https://fcm.googleapis.com/test')
        expect(payload[:p256dh]).to eq('public-key')
        expect(payload[:auth]).to eq('auth-key')
        expect(payload[:vapid]).to include(subject: 'https://crm.example', public_key: 'vapid-public', private_key: 'vapid-private')
        expect(JSON.parse(payload[:message])).to include('body' => 'Ana: Olá', 'url' => '/conversations/123')
      end
    end

    it 'does not send to an invalid subscription' do
      allow(subscription).to receive(:valid?).and_return(false)
      service.send(:send_browser_push, subscription)
      expect(WebPush).not_to have_received(:payload_send)
    end
  end

  it 'requires an appropriate VAPID subject instead of using an empty frontend URL' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('VAPID_SUBJECT').and_return('')
    allow(ENV).to receive(:[]).with('FRONTEND_URL').and_return('')
    expect { VapidService.subject }.to raise_error(ArgumentError, /VAPID_SUBJECT/)
    allow(ENV).to receive(:[]).with('FRONTEND_URL').and_return('https://crm.example')
    expect(VapidService.subject).to eq('https://crm.example')
  end
end
