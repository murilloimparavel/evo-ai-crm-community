require 'rails_helper'

RSpec.describe 'Notification subscriptions', type: :request do
  let!(:user) { User.create!(name: 'Push User', email: "push-#{SecureRandom.hex(4)}@example.com") }
  let!(:other_user) { User.create!(name: 'Other User', email: "other-#{SecureRandom.hex(4)}@example.com") }
  let(:endpoint) { 'https://fcm.googleapis.com/fcm/send/example' }
  let(:attributes) { { endpoint: endpoint, p256dh: 'a' * 87, auth: 'b' * 22 } }

  # Authentication is covered elsewhere; isolate subscription ownership in these request specs.
  # rubocop:disable RSpec/AnyInstance
  before do
    allow_any_instance_of(Api::V1::NotificationSubscriptionsController).to receive(:authenticate_request!).and_return(true)
    allow_any_instance_of(Api::V1::NotificationSubscriptionsController).to receive(:current_user).and_return(user)
  end

  # rubocop:enable RSpec/AnyInstance

  it 'returns the public key without the private key' do
    allow(VapidService).to receive(:public_key).and_return('public-key')
    get '/api/v1/notification_subscriptions'
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('vapid_public_key' => 'public-key')
  end

  it 'creates a browser subscription without echoing credentials' do
    post '/api/v1/notification_subscriptions',
         params: { notification_subscription: { subscription_type: 'browser_push', subscription_attributes: attributes } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(user.notification_subscriptions.browser_push.count).to eq(1)
    expect(response.body).not_to include(endpoint, attributes[:p256dh], attributes[:auth])
  end

  it 'does not delete another user’s subscription' do
    subscription = other_user.notification_subscriptions.create!(
      subscription_type: :browser_push, identifier: endpoint, subscription_attributes: attributes
    )
    delete '/api/v1/notification_subscriptions', params: { endpoint: endpoint }, as: :json
    expect(response).to have_http_status(:ok)
    expect(NotificationSubscription.exists?(subscription.id)).to be(true)
  end
end
