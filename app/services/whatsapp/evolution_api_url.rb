require 'uri'

module Whatsapp
  class EvolutionApiUrl
    class InvalidUrl < ArgumentError; end

    MANAGER_PATH = %r{(?:\A|/)manager\z}i.freeze
    VALID_PORT_RANGE = (1..65_535).freeze

    def self.normalize(value)
      raw_url = value.to_s.strip
      return nil if raw_url.blank?

      candidate = raw_url.match?(%r{\A[a-z][a-z0-9+.-]*://}i) ? raw_url : "https://#{raw_url}"
      uri = URI.parse(candidate)

      unless uri.is_a?(URI::HTTP) && uri.host.present? && VALID_PORT_RANGE.cover?(uri.port)
        raise InvalidUrl, 'Evolution API URL must be an HTTP(S) URL with a valid host and port.'
      end
      if uri.userinfo.present? || uri.query.present? || uri.fragment.present?
        raise InvalidUrl, 'Evolution API URL cannot contain credentials, query parameters, or a fragment.'
      end

      uri.scheme = uri.scheme.downcase
      uri.host = uri.host.downcase
      path = uri.path.to_s.sub(%r{/+\z}, '')
      path = path.sub(MANAGER_PATH, '')
      uri.path = path
      uri.to_s.sub(%r{/+\z}, '')
    rescue URI::InvalidURIError
      raise InvalidUrl, 'Evolution API URL is invalid. Enter a hostname such as https://evo.caldasindica.com.'
    end
  end
end
