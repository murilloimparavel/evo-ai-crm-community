# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Instagram::SendOnInstagramService do
  subject(:service) { described_class.new(message: message) }

  let(:message) { instance_double(Message) }
  let(:channel) { instance_double(Channel::Instagram, instagram_id: '17841471623411290') }
  let(:payload) do
    {
      recipient: { id: 'sender-scoped-user-id' },
      message: { text: 'test message' }
    }
  end
  let(:response) do
    instance_double(
      HTTParty::Response,
      success?: true,
      parsed_response: { 'message_id' => 'ig-message-id' }
    )
  end

  before do
    allow(service).to receive(:channel).and_return(channel)
    allow(message).to receive(:update!)
  end

  describe '#send_message' do
    context 'when EvoHub proxy is enabled' do
      let(:url) { 'https://api.evohub.ai/meta/17841471623411290/messages' }

      before do
        allow(MetaBaseUrl).to receive_messages(enabled?: true, for: 'https://api.evohub.ai/meta')
        allow(EvolutionHub::ChannelReconciler)
          .to receive(:hub_channel_token_of).with(channel).and_return('hub-channel-token')
      end

      it 'sends the channel token as Bearer auth and does not send the Meta access token' do
        expect(channel).not_to receive(:access_token)
        expect(HTTParty).to receive(:post).with(
          url,
          body: payload,
          headers: {
            'Authorization' => 'Bearer hub-channel-token',
            'Content-Type' => 'application/json'
          }
        ).and_return(response)

        expect(service.send(:send_message, payload)).to eq('message_id' => 'ig-message-id')
      end

      it 'marks the message failed without sending when the Hub token is unavailable' do
        allow(EvolutionHub::ChannelReconciler).to receive(:hub_channel_token_of).with(channel).and_return(nil)
        allow(channel).to receive(:heal_from_hub_if_stale!).and_return(false)
        expect(channel).not_to receive(:access_token)
        expect(HTTParty).not_to receive(:post)
        expect(Messages::StatusUpdateService).to receive(:new).with(
          message,
          'failed',
          'EVOLUTION_HUB_CHANNEL_TOKEN_MISSING'
        ).and_return(instance_double(Messages::StatusUpdateService, perform: true))

        expect(service.send(:send_message, payload)).to be_nil
      end
    end

    context 'when EvoHub proxy is disabled' do
      it 'keeps using the Meta access token query parameter' do
        allow(MetaBaseUrl).to receive_messages(enabled?: false, for: 'https://graph.instagram.com/v23.0')
        allow(channel).to receive(:access_token).and_return('meta-access-token')
        expect(EvolutionHub::ChannelReconciler).not_to receive(:hub_channel_token_of)
        expect(HTTParty).to receive(:post).with(
          'https://graph.instagram.com/v23.0/17841471623411290/messages',
          body: payload,
          query: { access_token: 'meta-access-token' }
        ).and_return(response)

        expect(service.send(:send_message, payload)).to eq('message_id' => 'ig-message-id')
      end
    end
  end
end
