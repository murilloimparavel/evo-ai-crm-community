# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require_relative '../../../app/services/ai/jev_client'

RSpec.describe Ai::JevClient do
  let(:questions) do
    {
      'intent' => { 'type' => 'choice', 'instructions' => 'Who must act?', 'criteria' => { 'customer' => 'Customer', 'unclear' => 'Unknown' } },
      'stop' => { 'type' => 'noul', 'instructions' => 'Stop contact?', 'criteria' => { 'true' => 'Explicit refusal', 'false' => 'No refusal' } }
    }
  end
  let(:data) do
    { 'model' => described_class::MODEL,
      'answers' => { 'intent' => { 'type' => 'choice', 'choice' => 'customer', 'confidence' => 0.98,
                                   'probabilities' => { 'customer' => 0.99, 'unclear' => 0.01 } },
                     'stop' => { 'type' => 'noul', 'noul' => 0.01 } },
      'usage' => { 'input_tokens' => 327, 'output_tokens' => 12 } }
  end
  let(:transport) { ->(**_args) { { status: 200, body: JSON.generate(data) } } }
  let(:client) { described_class.new(api_key: 'test-dummy', transport: transport) }

  def classify
    client.call(state: { messages: [{ role: 'customer', content: 'I will choose later' }] }, questions: questions)
  end

  it 'returns closed typed answers and known billable input tokens in one request' do
    calls = []
    recording = lambda do |**args|
      calls << args
      { status: 200, body: JSON.generate(data) }
    end
    result = described_class.new(api_key: 'dummy', transport: recording).call(state: {}, questions: questions)
    expect(result).to include(ok: true, model: 'jev-1.14.0', input_tokens: 327, usage_known: true)
    expect(calls.size).to eq(1)
    expect(JSON.parse(calls.first[:body]).keys).to contain_exactly('state', 'model', 'questions')
    expect(calls.first[:timeout]).to eq(10)
  end

  it 'disables actual HTTP by default even with an available key' do
    expect(described_class.new(api_key: 'dummy').call(state: {},
                                                      questions: questions)).to include(
                                                        ok: false, reason: 'live_requests_disabled', input_tokens: 0
                                                      )
    expect(WebMock).not_to have_requested(:post, described_class::ENDPOINT.to_s)
  end

  it 'requires runtime opt-in independently of a caller authorization' do
    previous = ENV.delete('JEV_LIVE_REQUESTS_ENABLED')
    expect(described_class.new(api_key: 'dummy', live_authorized: true).call(state: {},
                                                                             questions: questions)[:reason]).to eq('live_requests_disabled')
  ensure
    ENV['JEV_LIVE_REQUESTS_ENABLED'] = previous if previous
  end

  it 'uses the fixed HTTPS endpoint and does not follow redirects' do
    previous = ENV.fetch('JEV_LIVE_REQUESTS_ENABLED', nil)
    ENV['JEV_LIVE_REQUESTS_ENABLED'] = 'true'
    stub_request(:post, described_class::ENDPOINT.to_s).to_return(status: 302, headers: { Location: 'https://invalid.example' })
    result = described_class.new(api_key: 'dummy', live_authorized: true).call(state: {}, questions: questions)
    expect(result).to include(ok: false, reason: 'provider_http_302', retryable: false, usage_known: false)
    expect(WebMock).to have_requested(:post, described_class::ENDPOINT.to_s).once
  ensure
    ENV['JEV_LIVE_REQUESTS_ENABLED'] = previous
  end

  it 'retains usage on an invalid response model' do
    data['model'] = 'jev-latest'
    expect(classify).to include(ok: false, input_tokens: 327, usage_known: true)
  end

  it 'rejects a missing question' do
    data['answers'].delete('stop')
    expect(classify).to include(ok: false, reason: 'invalid_provider_schema')
  end

  it 'rejects an unexpected question instead of consuming model-selected fields' do
    data['answers']['send_to_url'] = { 'type' => 'noul', 'noul' => 1 }
    expect(classify[:ok]).to be(false)
  end

  it 'rejects unknown options and incomplete or unnormalized distributions' do
    answer = data['answers']['intent']
    answer['choice'] = 'inject'
    expect(classify[:ok]).to be(false)
    answer['choice'] = 'customer'
    answer['probabilities'] = { 'customer' => 1 }
    expect(classify[:ok]).to be(false)
    answer['probabilities'] = { 'customer' => 0.8, 'unclear' => 0.8 }
    expect(classify[:ok]).to be(false)
  end

  it 'rejects numeric strings, out of domain values and non-finite JSON' do
    ['0.9', -0.1, 1.1, nil].each do |value|
      data['answers']['stop']['noul'] = value
      expect(classify[:ok]).to be(false)
    end
    invalid = described_class.new(transport: ->(**_args) { { status: 200, body: '{"noul":NaN}' } })
    expect(invalid.call(state: {}, questions: questions)[:ok]).to be(false)
  end

  it 'rejects fabricated Noul confidence and free text answer fields' do
    data['answers']['stop']['confidence'] = 1
    expect(classify[:ok]).to be(false)
  end

  it 'keeps unknown usage unknown on timeout with no automatic retries' do
    count = 0
    timed = described_class.new(transport: lambda { |**_args|
      count += 1
      raise Net::ReadTimeout
    })
    expect(timed.call(state: {}, questions: questions)).to include(ok: false, usage_known: false, input_tokens: nil, retryable: true)
    expect(count).to eq(1)
  end

  it 'classifies transient HTTP errors and bounds Retry-After without retrying' do
    [429, 529].each do |status|
      transient = described_class.new(transport: ->(**_args) { { status: status, body: 'do not log body', headers: { 'Retry-After' => '99999' } } })
      expect(transient.call(state: {}, questions: questions)).to include(ok: false, retryable: true, retry_after: 3600, usage_known: false)
    end
  end

  it 'does not retry authentication and input errors' do
    [400, 401, 413, 415, 422].each do |status|
      invalid = described_class.new(transport: ->(**_args) { { status: status, body: 'sensitive provider body' } })
      expect(invalid.call(state: {}, questions: questions)).to include(ok: false, retryable: false, reason: "provider_http_#{status}")
    end
  end

  it 'bounds request and response bytes' do
    expect(client.call(state: 'é' * 7000, questions: questions)).to include(ok: false, reason: 'request_too_large')
    huge = described_class.new(transport: ->(**_args) { { status: 200, body: 'a' * ((64 * 1024) + 1) } })
    expect(huge.call(state: {}, questions: questions)).to include(ok: false, reason: 'invalid_provider_schema')
  end

  it 'does not treat absent usage as a free successful request' do
    data.delete('usage')
    expect(classify).to include(ok: false, usage_known: false, input_tokens: nil)
  end

  it 'supports Score with closed finite levels, legend and weighted mean validation' do
    questions.clear
    questions['urgency'] = { 'type' => 'score', 'instructions' => 'Urgency?', 'criteria' => %w[Routine Soon Immediate] }
    data['answers'] = { 'urgency' => { 'type' => 'score', 'score' => 1.43, 'confidence' => 0.35,
                                       'legend' => { '0' => 'Routine', '1' => 'Soon', '2' => 'Immediate' },
                                       'probabilities' => { '0' => 0.0, '1' => 0.57, '2' => 0.43 } } }
    expect(classify[:ok]).to be(true)
    data['answers']['urgency']['score'] = 999
    expect(classify[:ok]).to be(false)
    data['answers']['urgency']['score'] = 0
    expect(classify[:ok]).to be(false)
  end
end
