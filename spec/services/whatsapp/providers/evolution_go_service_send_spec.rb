# frozen_string_literal: true

require 'rails_helper'

# The send-response contract consumed by SendOnWhatsappService: a delivered
# send without an ID must not read as a failure.
RSpec.describe Whatsapp::Providers::EvolutionGoService do
  let(:whatsapp_channel) do
    instance_double(
      Channel::Whatsapp,
      provider_config: {
        'api_key' => 'token', 'instance_name' => 'inst', 'api_url' => 'https://evo-go.example.com',
        'instance_token' => 'instance-token'
      }
    )
  end
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }

  describe '#process_evolution_go_response' do
    it 'returns the message id when the API provides one' do
      response = instance_double(
        HTTParty::Response,
        success?: true, code: 200,
        parsed_response: { 'data' => { 'Info' => { 'ID' => 'GO123' } }, 'message' => 'success' },
        body: '{}'
      )

      expect(service.send(:process_evolution_go_response, response)).to eq('GO123')
    end

    it 'returns true (success without id) when HTTP 200 carries no ID' do
      response = instance_double(
        HTTParty::Response,
        success?: true, code: 200,
        parsed_response: { 'message' => 'success' },
        body: '{}'
      )

      expect(service.send(:process_evolution_go_response, response)).to be(true)
    end

    it 'raises on HTTP error (handled by SendReplyJob rescue)' do
      response = instance_double(
        HTTParty::Response,
        success?: false, code: 500,
        parsed_response: {},
        body: 'boom'
      )

      expect { service.send(:process_evolution_go_response, response) }
        .to raise_error(/HTTP 500/)
    end
  end

  describe '#toggle_typing_status' do
    it 'uses Evolution Go chat presence contract and instance authentication' do
      allow(HTTParty).to receive(:post).and_return(instance_double(HTTParty::Response, success?: true))

      expect(service.toggle_typing_status('+5511999999999', 'conversation.typing_on')).to be(true)
      expect(HTTParty).to have_received(:post) do |url, options|
        expect(url).to eq('https://evo-go.example.com/message/presence')
        expect(JSON.parse(options[:body])).to eq(
          'number' => '5511999999999', 'state' => 'composing'
        )
        expect(options[:headers]['apikey']).to eq('instance-token')
      end
    end

    it 'maps typing off to paused and recording to the audio indicator' do
      allow(HTTParty).to receive(:post).and_return(instance_double(HTTParty::Response, success?: true))

      expect(service.toggle_typing_status('5511999999999', 'conversation.typing_off')).to be(true)
      expect(service.send(:evolution_go_presence_for, 'conversation.recording')).to eq('recording')
      expect(HTTParty).to have_received(:post).once do |_url, options|
        expect(JSON.parse(options[:body])['state']).to eq('paused')
      end
    end
  end

  describe '#send_message — unsupported content (CRM-448)' do
    it 'flags the message is_unsupported and returns nil (the caller turns it into failed)' do
      message = instance_double(Message, attachments: [], content_type: 'text', content: nil)
      expect(message).to receive(:update!).with(is_unsupported: true)

      expect(service.send_message('5511999999999', message)).to be_nil
    end
  end
end
