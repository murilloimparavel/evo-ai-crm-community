class Notification::PushNotificationService
  include Rails.application.routes.url_helpers

  pattr_initialize [:notification!]

  def perform
    Rails.logger.info("📱 [PUSH] Processing push notification for user #{user.email}, notification_type: #{notification.notification_type}")

    unless user_subscribed_to_notification?
      Rails.logger.info("📱 [PUSH] User #{user.email} not subscribed to push notifications for #{notification.notification_type}")
      return
    end

    Rails.logger.info("📱 [PUSH] User #{user.email} has #{notification_subscriptions.count} notification subscription(s)")

    notification_subscriptions.each do |subscription|
      send_browser_push(subscription)
      send_fcm_push(subscription)
      send_push_via_evolution_hub(subscription)
    end
  end

  private

  delegate :user, to: :notification
  delegate :notification_subscriptions, to: :user
  delegate :notification_settings, to: :user

  def user_subscribed_to_notification?
    notification_setting = notification_settings.first
    return true if notification_setting&.public_send("push_#{notification.notification_type}?")

    false
  end

  def conversation
    @conversation ||= notification.conversation
  end

  def push_message
    {
      title: [channel_label, notification.push_message_title].reject(&:blank?).join(' · '),
      body: 'Abra o app para ver a mensagem.',
      notification_id: notification.id,
      user_id: user.id,
      channel: channel_label,
      tag: "notification-#{notification.id}",
      url: push_url
    }
  end

  def channel_label
    inbox = conversation.try(:inbox)
    return 'SOFIA Central' unless inbox

    type = inbox.channel_type.to_s.delete_prefix('Channel::')
    type = 'WhatsApp' if type.casecmp('whatsapp').zero?
    [type, inbox.name].reject(&:blank?).uniq.join(' · ')
  end

  def push_url
    "#{ENV.fetch('FRONTEND_URL', 'http://localhost:3000').delete_suffix('/')}/conversations/#{conversation.display_id}"
  end

  def can_send_browser_push?(subscription)
    VapidService.public_key && subscription.browser_push?
  end

  def browser_push_payload(subscription)
    {
      message: JSON.generate(push_message),
      endpoint: subscription.subscription_attributes['endpoint'],
      p256dh: subscription.subscription_attributes['p256dh'],
      auth: subscription.subscription_attributes['auth'],
      vapid: {
        subject: push_url,
        public_key: VapidService.public_key,
        private_key: VapidService.private_key
      },
      ssl_timeout: 5,
      open_timeout: 5,
      read_timeout: 5
    }
  end

  def send_browser_push(subscription)
    return unless can_send_browser_push?(subscription)

    WebPush.payload_send(**browser_push_payload(subscription))
    Rails.logger.info("Browser push sent to #{user.email} with title #{push_message[:title]}")
  rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription => e
    Rails.logger.info "WebPush subscription expired: #{e.message}"
    subscription.destroy!
  rescue Errno::ECONNRESET, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error "WebPush operation error: #{e.message}"
  rescue StandardError => e
    EvolutionExceptionTracker.new(e, account: nil).capture_exception
    true
  end

  def send_fcm_push(subscription)
    return unless firebase_credentials_present? && subscription.fcm?

    begin
      project_id = GlobalConfigService.load('FIREBASE_PROJECT_ID', nil)
      credentials = GlobalConfigService.load('FIREBASE_CREDENTIALS_SECRET', nil)

      fcm_service = Notification::FcmService.new(project_id, credentials)
      fcm = fcm_service.fcm_client
      response = fcm.send_v1(fcm_options(subscription))
      remove_subscription_if_error(subscription, response)
    rescue StandardError => e
      Rails.logger.error("❌ [FCM] Error sending push to #{user.email}: #{e.class} - #{e.message}")
      Rails.logger.error("❌ [FCM] Backtrace: #{e.backtrace.first(5).join("\n")}")
      EvolutionExceptionTracker.new(e, account: nil).capture_exception
    end
  end

  def send_push_via_evolution_hub(subscription)
    return if firebase_credentials_present?
    return unless evolution_hub_enabled?
    return unless subscription.fcm?

    EvolutionHubTelemetry.send_push(fcm_options(subscription))
  end

  def firebase_credentials_present?
    project_id = GlobalConfigService.load('FIREBASE_PROJECT_ID', nil)
    credentials = GlobalConfigService.load('FIREBASE_CREDENTIALS_SECRET', nil)

    if project_id.present? && credentials.present?
      Rails.logger.info("✅ [FCM] Firebase credentials found (Project ID: #{project_id})")
      true
    else
      Rails.logger.info('FCM credentials missing')
      false
    end
  end

  def evolution_hub_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('ENABLE_PUSH_RELAY_SERVER', true))
  end

  def remove_subscription_if_error(subscription, response)
    parsed_response = JSON.parse(response[:body])
    result = parsed_response['results']&.first

    if result&.keys&.include?('error')
      error_code = result['error']
      Rails.logger.error("❌ [FCM] Push failed for #{user.email}: #{error_code}")
      Rails.logger.error("❌ [FCM] Response: #{parsed_response.inspect}")
      subscription.destroy!
    else
      message_id = parsed_response['name'] || result&.dig('messageId') || 'unknown'
      Rails.logger.info("✅ [FCM] Push sent successfully to #{user.email} with title '#{push_message[:title]}' (Message ID: #{message_id})")
    end
  end

  def fcm_options(subscription)
    {
      'token': subscription.subscription_attributes['push_token'],
      'data': fcm_data,
      'notification': fcm_notification,
      'android': fcm_android_options,
      'apns': fcm_apns_options,
      'fcm_options': {
        analytics_label: 'Label'
      }
    }
  end

  def fcm_data
    {
      payload: {
        data: {
          notification: notification.fcm_push_data
        }
      }.to_json
    }
  end

  def fcm_notification
    {
      title: notification.push_message_title,
      body: notification.push_message_body
    }
  end

  def fcm_android_options
    {
      priority: 'high'
    }
  end

  def fcm_apns_options
    {
      payload: {
        aps: {
          sound: 'default',
          category: Time.zone.now.to_i.to_s
        }
      }
    }
  end
end
