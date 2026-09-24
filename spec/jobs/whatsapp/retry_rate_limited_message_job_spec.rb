# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::RetryRateLimitedMessageJob do
  let(:attributes) do
    {
      'whatsapp_auto_retry_count' => 1,
      'whatsapp_auto_retry_http_status' => 429,
      'whatsapp_auto_retry_token' => 'retry-token-1',
      'external_error' => 'HTTP 429'
    }
  end
  let(:message) do
    instance_double(Message,
                    id: 44,
                    content_attributes: attributes,
                    outgoing?: true,
                    private?: false,
                    failed?: true,
                    source_id: nil)
  end

  it 'claims a matching rate-limited failed message and invokes SendReplyJob' do
    allow(described_class).to receive(:new).and_call_original
    allow(Message).to receive(:find_by).with(id: 44).and_return(message)
    allow(message).to receive(:with_lock) { |&block| block.call }
    expect(message).to receive(:update!).with(
      status: :sent,
      content_attributes: {
        'whatsapp_auto_retry_count' => 1,
        'whatsapp_auto_retry_http_status' => 429,
        'whatsapp_auto_retry_token' => 'retry-token-1'
      }
    )
    expect(SendReplyJob).to receive(:perform_now).with(44)

    described_class.perform_now(44, 1, 'retry-token-1')
  end

  it 'does not send when a manual retry or another status update made the job stale' do
    allow(Message).to receive(:find_by).with(id: 44).and_return(message)
    allow(message).to receive(:with_lock) { |&block| block.call }
    allow(message).to receive(:source_id).and_return('accepted-by-provider')

    expect(message).not_to receive(:update!)
    expect(SendReplyJob).not_to receive(:perform_now)

    described_class.perform_now(44, 1, 'retry-token-1')
  end
  it 'does not send when a newer retry replaced the queued job token' do
    allow(Message).to receive(:find_by).with(id: 44).and_return(message)
    allow(message).to receive(:with_lock) { |&block| block.call }
    allow(message).to receive(:content_attributes).and_return(
      attributes.merge('whatsapp_auto_retry_token' => 'newer-token')
    )

    expect(message).not_to receive(:update!)
    expect(SendReplyJob).not_to receive(:perform_now)

    described_class.perform_now(44, 1, 'retry-token-1')
  end

end
