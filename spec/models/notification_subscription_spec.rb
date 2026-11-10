require 'rails_helper'

RSpec.describe NotificationSubscription, type: :model do
  let(:user) { User.create!(name: 'Push User', email: "push-#{SecureRandom.hex(4)}@example.com") }
  let(:attributes) { { 'endpoint' => 'https://fcm.googleapis.com/fcm/send/example', 'p256dh' => 'a' * 87, 'auth' => 'b' * 22 } }
  subject(:subscription) { described_class.new(user: user, subscription_type: :browser_push, identifier: attributes['endpoint'], subscription_attributes: attributes) }

  it 'accepts a browser push service endpoint' do
    expect(subscription).to be_valid
  end

  it 'rejects endpoints pointing at internal services' do
    attributes['endpoint'] = 'https://127.0.0.1/admin'
    expect(subscription).not_to be_valid
  end

  it 'rejects lookalike hosts and nonstandard ports' do
    attributes['endpoint'] = 'https://fcm.googleapis.com.attacker.example/test'
    expect(subscription).not_to be_valid
    attributes['endpoint'] = 'https://fcm.googleapis.com:8443/test'
    expect(subscription).not_to be_valid
  end

  it 'requires both encryption keys' do
    attributes.delete('auth')
    expect(subscription).not_to be_valid
  end
end
