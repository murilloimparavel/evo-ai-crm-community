# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::Providers::BaseService do
  subject(:service) { described_class.new(whatsapp_channel: instance_double(Channel::Whatsapp)) }

  describe '#process_response' do
    it 'keeps the provider status and a sanitized error without logging the raw body' do
      response = instance_double(
        HTTParty::Response,
        success?: false,
        code: 429,
        parsed_response: { 'error' => { 'code' => 'RATE_LIMIT', 'message' => 'Too many requests to 15551234567' } },
        body: '{"sensitive":"raw body"}'
      )

      expect(Rails.logger).to receive(:error).with('[WhatsAppProvider] response_status=429 error=RATE_LIMIT: Too many requests to [number]')
      expect(service.send(:process_response, response)).to be_nil
      expect(service.last_delivery_status).to eq(429)
      expect(service.last_delivery_error).to eq('RATE_LIMIT: Too many requests to [number]')
    end

    it 'does not retain a non-JSON provider body' do
      response = instance_double(HTTParty::Response, success?: false, code: 503, parsed_response: '<html>private response</html>', body: '<html>private response</html>')

      allow(Rails.logger).to receive(:error)
      service.send(:process_response, response)

      expect(service.last_delivery_error).to eq('Provider returned HTTP 503')
    end

    it 'keeps nested provider details when the top-level error is generic' do
      response = instance_double(
        HTTParty::Response,
        success?: false,
        code: 400,
        parsed_response: {
          'status' => 400,
          'error' => 'Bad Request',
          'response' => { 'message' => ['The instance is not connected'] }
        },
        body: ''
      )

      expect(Rails.logger).to receive(:error).with('[WhatsAppProvider] response_status=400 error=The instance is not connected')
      service.send(:process_response, response)

      expect(service.last_delivery_status).to eq(400)
      expect(service.last_delivery_error).to eq('The instance is not connected')
    end

    it 'redacts phone numbers and API keys in nested provider details' do
      response = instance_double(
        HTTParty::Response,
        success?: false,
        code: 400,
        parsed_response: {
          'error' => 'Bad Request',
          'response' => { 'message' => 'Invalid recipient +15551234567; apikey=123e4567-e89b-12d3-a456-426614174000' }
        },
        body: ''
      )

      allow(Rails.logger).to receive(:error)
      service.send(:process_response, response)

      expect(service.last_delivery_error).to eq('Invalid recipient [number]; apikey=[redacted]')
    end
  end
end
