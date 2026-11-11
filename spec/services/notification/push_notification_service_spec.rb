require 'rails_helper'

RSpec.describe Notification::PushNotificationService do
  subject(:service) { described_class.new(notification: notification) }

  let(:conversation) { instance_double(Conversation, display_id: 123) }
  let(:push_recipient) { instance_double(User, id: 'user-1') }
  let(:notification) do
    instance_double(
      Notification, user: push_recipient, conversation: conversation, push_message_title: 'Conversa #123', push_message_body: 'Ana: Olá',
                    notification_type: 'assigned_conversation_new_message', id: 'notification-id'
    )
  end

  it 'includes the sender and preview and links to the Sofia conversation' do
    payload = service.send(:push_message)
    expect(payload[:body]).to eq('Ana: Olá')
    expect(payload[:url]).to end_with('/conversations/123')
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
        expect(JSON.parse(payload[:message])['body']).to eq('Ana: Olá')
        expect(JSON.parse(payload[:message])['url']).to end_with('/conversations/123')
      end
    end

    it 'does not send to an untrusted endpoint' do
      allow(subscription).to receive(:subscription_attributes).and_return('endpoint' => 'https://127.0.0.1/private')
      service.send(:send_browser_push, subscription)
      expect(WebPush).not_to have_received(:payload_send)
    end
  end

  describe 'user preferences' do
    let(:user) { User.new(email: 'agent@example.com') }
    let(:setting) { NotificationSetting.new }
    let(:subscription) do
      instance_double(NotificationSubscription, id: 'one', subscription_type: 'browser_push', browser_push?: true,
                                                valid?: true, fcm?: false,
                                                subscription_attributes: { 'endpoint' => 'https://fcm.googleapis.com/test',
                                                                           'p256dh' => 'public-key', 'auth' => 'auth-key' })
    end

    before do
      allow(notification).to receive(:user).and_return(user)
      allow(user).to receive_messages(notification_settings: [setting], notification_subscriptions: [subscription])
      allow(VapidService).to receive_messages(public_key: 'public', private_key: 'private', subject: 'https://crm.example')
      allow(GlobalConfigService).to receive(:load).and_return(nil)
      allow(WebPush).to receive(:payload_send)
    end

    it 'sends to the user subscriptions when the message preference is enabled' do
      allow(setting).to receive(:push_assigned_conversation_new_message?).and_return(true)
      service.perform
      expect(WebPush).to have_received(:payload_send)
    end

    it 'does not send when the message preference is disabled' do
      allow(setting).to receive(:push_assigned_conversation_new_message?).and_return(false)
      service.perform
      expect(WebPush).not_to have_received(:payload_send)
    end

    it 'does not send when the user has no notification settings' do
      allow(user).to receive(:notification_settings).and_return([])
      service.perform
      expect(WebPush).not_to have_received(:payload_send)
    end
  end

  it 'rejects a partially configured VAPID key pair before generating or persisting keys' do
    allow(GlobalConfig).to receive(:get).with('VAPID_KEYS').and_return('VAPID_KEYS' => nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('VAPID_PUBLIC_KEY').and_return('configured-public')
    allow(ENV).to receive(:[]).with('VAPID_PRIVATE_KEY').and_return('')
    expect(WebPush).not_to receive(:generate_key)
    expect { VapidService.public_key }.to raise_error(ArgumentError, /both VAPID keys/)
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
