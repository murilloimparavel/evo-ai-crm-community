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

    # A half-configured pair must never be combined with a freshly generated key.
    public_key = ENV['VAPID_PUBLIC_KEY'].presence
    private_key = ENV['VAPID_PRIVATE_KEY'].presence
    raise ArgumentError, 'Configure both VAPID keys or neither' if public_key.present? != private_key.present?

    if public_key.blank?
      keys = WebPush.generate_key
      public_key = keys.public_key
      private_key = keys.private_key
    end

    i = InstallationConfig.where(name: 'VAPID_KEYS').first_or_create!(value: { public_key: public_key, private_key: private_key })
    i.value
  end

  private_class_method :vapid_keys
end
