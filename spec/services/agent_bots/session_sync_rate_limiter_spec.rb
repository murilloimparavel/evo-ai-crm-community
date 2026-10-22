# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBots::SessionSyncRateLimiter do
  it 'uses a shared Redis token bucket with the configured per-minute rate' do
    previous = ENV.fetch('SESSION_SYNC_RATE_LIMIT_PER_MINUTE', nil)
    ENV['SESSION_SYNC_RATE_LIMIT_PER_MINUTE'] = '30'
    redis = instance_double(Redis, eval: 0.0)
    allow(Sidekiq).to receive(:redis).and_yield(redis)

    expect(redis).to receive(:eval) do |_script, keys: _keys, argv:|
      expect(keys).to eq([described_class::REDIS_KEY])
      expect(argv[1]).to eq(0.5)
      expect(argv[2]).to eq(5)
      expect(argv[3]).to eq(70)
      0.0
    end

    expect(described_class.acquire_delay).to eq(0.0)
  ensure
    previous.nil? ? ENV.delete('SESSION_SYNC_RATE_LIMIT_PER_MINUTE') : ENV['SESSION_SYNC_RATE_LIMIT_PER_MINUTE'] = previous
  end

  it 'clamps the configured rate to a safe maximum' do
    previous = ENV.fetch('SESSION_SYNC_RATE_LIMIT_PER_MINUTE', nil)
    ENV['SESSION_SYNC_RATE_LIMIT_PER_MINUTE'] = '9999'
    redis = instance_double(Redis)
    allow(Sidekiq).to receive(:redis).and_yield(redis)
    expect(redis).to receive(:eval) do |_script, keys: _keys, argv:|
      expect(argv[1]).to eq(10.0)
      expect(argv[2]).to eq(5)
      expect(argv[3]).to eq(61)
      0.0
    end

    expect(described_class.acquire_delay).to eq(0.0)
  ensure
    previous.nil? ? ENV.delete('SESSION_SYNC_RATE_LIMIT_PER_MINUTE') : ENV['SESSION_SYNC_RATE_LIMIT_PER_MINUTE'] = previous
  end

  it 'fails open on malformed configuration rather than endlessly deferring jobs' do
    previous = ENV.fetch('SESSION_SYNC_RATE_LIMIT_PER_MINUTE', nil)
    ENV['SESSION_SYNC_RATE_LIMIT_PER_MINUTE'] = 'invalid'
    allow(Rails.logger).to receive(:error)

    expect(described_class.acquire_delay).to eq(0.0)
    expect(Rails.logger).to have_received(:error).with(/Invalid rate-limit configuration/)
  ensure
    previous.nil? ? ENV.delete('SESSION_SYNC_RATE_LIMIT_PER_MINUTE') : ENV['SESSION_SYNC_RATE_LIMIT_PER_MINUTE'] = previous
  end
end
