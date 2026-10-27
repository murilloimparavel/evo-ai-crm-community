require 'rails_helper'

# HTTParty responses and downloaded temporary files expose dynamic interfaces.
# rubocop:disable RSpec/VerifiedDoubles

RSpec.describe Whatsapp::ConversationSyncService do
  let(:channel) { double('channel', media_url: 'https://graph.facebook.com/media-id', api_headers: { 'Authorization' => 'Bearer token' }) }
  let(:inbox) { double('inbox', channel: channel) }
  let(:service) { described_class.new(inbox: inbox, params: {}) }

  describe '#download_echo_attachment_file' do
    it 'downloads the binary URL from Meta metadata for audio and images' do
      %w[audio image].each do |type|
        url = "https://lookaside.facebook.com/#{type}"
        metadata = double('metadata', success?: true, parsed_response: { 'url' => url })
        file = double('file', content_type: type == 'audio' ? 'audio/ogg' : 'image/jpeg')
        allow(file).to receive(:read).with(1).and_return(type == 'audio' ? 'O' : "\xFF")
        allow(file).to receive(:rewind)
        expect(HTTParty).to receive(:get).with('https://graph.facebook.com/media-id', headers: channel.api_headers).and_return(metadata)
        expect(Down).to receive(:download).with(url, headers: channel.api_headers).and_return(file)
        expect(service.send(:download_echo_attachment_file, 'media-id')).to eq(file)
      end
    end

    it 'rejects JSON instead of attaching it as media' do
      metadata = double('metadata', success?: true, parsed_response: { 'url' => 'https://lookaside.facebook.com/media' })
      file = double('file', content_type: 'application/json')
      allow(file).to receive(:close!)
      allow(HTTParty).to receive(:get).and_return(metadata)
      allow(Down).to receive(:download).and_return(file)
      expect { service.send(:download_echo_attachment_file, 'media-id') }
        .to raise_error(described_class::EchoMediaDownloadError)
    end
  end
end
# rubocop:enable RSpec/VerifiedDoubles
