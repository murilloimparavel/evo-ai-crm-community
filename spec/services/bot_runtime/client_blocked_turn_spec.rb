# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::Client do
  it 'keeps the circuit closed for blocked conversations and allows another conversation' do
    breaker = BotRuntime::CircuitBreaker.new(max_failures: 5, reset_timeout: 30)
    stub_const('BotRuntime::Client::CIRCUIT_BREAKER', breaker)
    blocked = instance_double(Net::HTTPConflict, code: '409', body: '{"code":"ERR_TURN_BLOCKED"}')
    success = Net::HTTPOK.new('1.1', '200', 'OK')
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_return(blocked, blocked, blocked, blocked, blocked, success)
    allow(BotRuntime::Config).to receive(:url).and_return('http://localhost:12345')
    allow(BotRuntime::Config).to receive(:timeout).and_return(1)
    allow(BotRuntime::Config).to receive(:secret).and_return('test-secret')

    5.times { expect { subject.send_event({}) }.to raise_error(BotRuntime::Client::TurnBlockedError) }
    expect(breaker.state).to eq(:closed)
    expect(subject.send_event({})).to eq(success)
  end
end
