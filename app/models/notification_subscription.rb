# == Schema Information
#
# Table name: notification_subscriptions
#
#  id                      :uuid             not null, primary key
#  identifier              :string
#  subscription_attributes :jsonb            not null
#  subscription_type       :integer          not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  user_id                 :uuid             not null
#
# Indexes
#
#  index_notification_subscriptions_on_identifier  (identifier) UNIQUE
#  index_notification_subscriptions_on_user_id     (user_id)
#
class NotificationSubscription < ApplicationRecord
  belongs_to :user
  validates :identifier, presence: true
  validate :validate_browser_subscription, if: :browser_push?

  # Only browser-vendor push services are allowed. The endpoint is otherwise a
  # user-provided URL fetched by the server and can be abused for SSRF.
  BROWSER_PUSH_HOSTS = /\A(?:fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|\
(?:[a-z0-9-]+\.)*push\.apple\.com|(?:[a-z0-9-]+\.)*notify\.windows\.com)\z/ix

  def validate_browser_subscription
    attrs = subscription_attributes || {}
    errors.add(:subscription_attributes, 'contains an invalid push endpoint') unless valid_push_endpoint?(attrs['endpoint'])
    %w[p256dh auth].each do |key|
      errors.add(:subscription_attributes, "missing or invalid #{key}") unless attrs[key].to_s.match?(/\A[A-Za-z0-9_-]{16,128}\z/)
    end
  end

  def valid_push_endpoint?(endpoint)
    uri = URI.parse(endpoint.to_s)
    uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? &&
      uri.host.to_s.match?(BROWSER_PUSH_HOSTS) && uri.fragment.nil?
  rescue URI::InvalidURIError
    false
  end

  SUBSCRIPTION_TYPES = {
    browser_push: 1,
    fcm: 2
  }.freeze

  enum :subscription_type, SUBSCRIPTION_TYPES
end
