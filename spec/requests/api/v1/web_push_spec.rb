require 'rails_helper'

RSpec.describe 'Web Push subscriptions', type: :request do
  let(:user) { User.create!(name: 'Push operator', email: "push-#{SecureRandom.hex(5)}@example.test") }
  let(:other) { User.create!(name: 'Other operator', email: "other-#{SecureRandom.hex(5)}@example.test") }
  let(:keys) { WebPush.generate_key }
  let(:endpoint) { 'https://fcm.googleapis.com/fcm/send/synthetic-device' }
  let(:attributes) { { endpoint: endpoint, p256dh: 'synthetic-p256dh', auth: 'synthetic-auth' } }

  before do
    actor = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) { Current.user = actor } # rubocop:disable RSpec/AnyInstance
  end

  after { Current.reset }

  def subscribe
    post '/api/v1/notification_subscriptions', params: {
      notification_subscription: { subscription_type: 'browser_push', subscription_attributes: attributes }
    }, as: :json
  end

  it 'exposes the existing public VAPID key without returning private key material' do
    allow(VapidService).to receive(:public_key).and_return(keys.public_key)
    get '/api/v1/notification_subscriptions'
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('public_key' => keys.public_key)
    expect(response.body).not_to include(keys.private_key)
  end

  it 'initializes and reuses a persisted VAPID pair when none is configured' do
    InstallationConfig.where(name: 'VAPID_KEYS').delete_all
    GlobalConfig.clear_cache
    get '/api/v1/notification_subscriptions'
    expect(response).to have_http_status(:ok)
    public_key = response.parsed_body.fetch('public_key')
    expect(public_key).to be_present
    get '/api/v1/notification_subscriptions'
    expect(response.parsed_body.fetch('public_key')).to eq(public_key)
    expect(InstallationConfig.find_by!(name: 'VAPID_KEYS').value['private_key']).to be_present
  end

  it 'persists and renews a browser subscription without duplicates' do
    subscribe
    expect(response).to have_http_status(:ok)
    subscribe
    expect(response).to have_http_status(:ok)
    expect(user.notification_subscriptions.browser_push.count).to eq(1)
    expect(user.notification_subscriptions.first.subscription_attributes).to include(attributes.stringify_keys)
  end

  it 'moves a shared browser to its newly authenticated user' do
    other.notification_subscriptions.create!(subscription_type: :browser_push, identifier: endpoint, subscription_attributes: attributes)
    subscribe
    expect(response).to have_http_status(:ok)
    expect(user.notification_subscriptions.count).to eq(1)
    expect(other.notification_subscriptions.count).to eq(0)
  end

  it 'cannot unsubscribe another user and preserves other devices during logout' do
    own = user.notification_subscriptions.create!(subscription_type: :browser_push, identifier: endpoint, subscription_attributes: attributes)
    foreign_endpoint = "#{endpoint}-other"
    foreign = other.notification_subscriptions.create!(subscription_type: :browser_push, identifier: foreign_endpoint,
                                                       subscription_attributes: attributes.merge(endpoint: foreign_endpoint))
    delete '/api/v1/notification_subscriptions', params: { endpoint: foreign_endpoint }, as: :json
    expect(response).to have_http_status(:ok)
    expect(NotificationSubscription.exists?(foreign.id)).to be(true)
    delete '/api/v1/notification_subscriptions', params: { endpoint: endpoint }, as: :json
    expect(NotificationSubscription.exists?(own.id)).to be(false)
    expect(NotificationSubscription.exists?(foreign.id)).to be(true)
  end

  it 'does not delete every subscription when the request has no endpoint or token' do
    subscribe
    delete '/api/v1/notification_subscriptions', as: :json
    expect(user.notification_subscriptions.count).to eq(1)
  end

  it 'rejects a request without authentication' do
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!).and_call_original # rubocop:disable RSpec/AnyInstance
    get '/api/v1/notification_subscriptions'
    expect(response).to have_http_status(:unauthorized)
  end
end
