class VapidService
  def self.public_key
    vapid_keys['public_key']
  end

  def self.private_key
    vapid_keys['private_key']
  end

  def self.subject
    subject = ENV['VAPID_SUBJECT'].presence || ENV['FRONTEND_URL'].presence
    uri = URI.parse(subject.to_s)
    return subject if uri.is_a?(URI::MailTo) || (uri.is_a?(URI::HTTPS) && uri.host.present?)

    raise ArgumentError, 'VAPID_SUBJECT or FRONTEND_URL must be a mailto or HTTPS URL'
  rescue URI::InvalidURIError
    raise ArgumentError, 'VAPID_SUBJECT or FRONTEND_URL must be a mailto or HTTPS URL'
  end

  def self.vapid_keys
    config = GlobalConfig.get('VAPID_KEYS')
    return config['VAPID_KEYS'] if config['VAPID_KEYS'].present?

    # keys don't exist in the database. so let's generate and save them
    keys = WebPush.generate_key
    # TODO: remove the logic on environment variables when we completely deprecate
    public_key = ENV.fetch('VAPID_PUBLIC_KEY') { keys.public_key }
    private_key = ENV.fetch('VAPID_PRIVATE_KEY') { keys.private_key }

    i = InstallationConfig.where(name: 'VAPID_KEYS').first_or_create!(value: { public_key: public_key, private_key: private_key })
    i.value
  end

  private_class_method :vapid_keys
end
