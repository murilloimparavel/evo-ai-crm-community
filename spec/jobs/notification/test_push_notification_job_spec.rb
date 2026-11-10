require 'rails_helper'

RSpec.describe Notification::TestPushNotificationJob do
  let(:user) { User.create!(name: 'Push tester', email: "test-push-#{SecureRandom.hex(5)}@example.test") }
  let(:subscription) do
    user.notification_subscriptions.create!(subscription_type: :browser_push, identifier: 'https://web.push.apple.com/synthetic',
                                            subscription_attributes: { endpoint: 'https://web.push.apple.com/synthetic',
                                                                       p256dh: 'key', auth: 'auth' })
  end

  before do
    key = WebPush.generate_key
    allow(VapidService).to receive_messages(public_key: key.public_key, private_key: key.private_key)
    allow(WebPush).to receive(:payload_send)
  end

  it 'sends the actual test payload through VAPID without needing event preferences' do
    described_class.perform_now(subscription.id, user.id)
    expect(WebPush).to have_received(:payload_send) do |**options|
      payload = JSON.parse(options[:message])
      expect(payload['user_id']).to eq(user.id)
      expect(payload['title']).to include('Teste de notificações')
      expect(payload['url']).to end_with('/profile/notificacoes')
    end
  end

  it 'does not send after the device has been removed or moved to another user' do
    id = subscription.id
    subscription.update!(user: User.create!(name: 'Other', email: "other-test-#{SecureRandom.hex(5)}@example.test"))
    described_class.perform_now(id, user.id)
    subscription.destroy!
    described_class.perform_now(id, user.id)
    expect(WebPush).not_to have_received(:payload_send)
  end

  it 'accepts the major mobile push providers and rejects internal, deceptive or non-HTTPS hosts' do
    expect(described_class.supported_endpoint?('https://fcm.googleapis.com/fcm/send/one')).to be(true)
    expect(described_class.supported_endpoint?('https://web.push.apple.com/one')).to be(true)
    expect(described_class.supported_endpoint?('https://updates.push.services.mozilla.com/one')).to be(true)
    expect(described_class.supported_endpoint?('http://fcm.googleapis.com/one')).to be(false)
    expect(described_class.supported_endpoint?('https://web.push.apple.com.attacker.test/one')).to be(false)
    expect(described_class.supported_endpoint?('https://127.0.0.1/one')).to be(false)
  end
end
