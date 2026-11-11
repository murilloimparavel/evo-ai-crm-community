class Notification::TestPushNotificationJob < ApplicationJob
  queue_as :default

  PUSH_HOSTS = %w[fcm.googleapis.com push.services.mozilla.com push.apple.com notify.windows.com wns.windows.com].freeze

  def self.supported_endpoint?(endpoint)
    uri = URI.parse(endpoint.to_s)
    uri.scheme == 'https' && uri.port == 443 && uri.userinfo.nil? &&
      PUSH_HOSTS.any? { |host| uri.host == host || uri.host.to_s.end_with?(".#{host}") }
  rescue URI::InvalidURIError
    false
  end

  def perform(subscription_id, user_id)
    subscription = NotificationSubscription.browser_push.find_by(id: subscription_id, user_id: user_id)
    return unless subscription && self.class.supported_endpoint?(subscription.identifier)

    WebPush.payload_send(**push_options(subscription, user_id))
  rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
    subscription&.destroy!
  end

  private

  def push_options(subscription, user_id)
    attributes = subscription.subscription_attributes.symbolize_keys.slice(:endpoint, :p256dh, :auth)
    origin = ENV.fetch('FRONTEND_URL', 'http://localhost:3000').delete_suffix('/')
    attributes.merge(
      message: { title: 'SOFIA Central · Teste de notificações', body: 'Este aparelho recebeu a notificação de teste.',
                 user_id: user_id, tag: "push-test-#{job_id}", url: "#{origin}/profile/notifications" }.to_json,
      vapid: { subject: VapidService.subject, public_key: VapidService.public_key, private_key: VapidService.private_key },
      ssl_timeout: 5, open_timeout: 5, read_timeout: 5
    )
  end
end
