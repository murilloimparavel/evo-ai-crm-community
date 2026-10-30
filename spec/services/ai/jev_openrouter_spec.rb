require 'spec_helper'
require 'webmock/rspec'
require_relative '../../../app/services/ai/jev_client'

RSpec.describe 'Jev through OpenRouter System One' do
  let(:questions) { { 'stage' => { 'type' => 'choice', 'instructions' => 'Select a stage.', 'criteria' => { 'offer' => 'Offer shared', 'unclear' => 'Unknown' } } } }
  let(:response) do
    { 'id' => 'gen-dec-synthetic', 'provider' => 'TypeSafe', 'model' => 'typesafe/jev-1.14-20261014',
      'answers' => { 'stage' => { 'type' => 'choice', 'choice' => 'offer', 'confidence' => 1.0, 'probabilities' => { 'offer' => 1.0, 'unclear' => 0.0 } } },
      'usage' => { 'input_tokens' => 100, 'output_tokens' => 12, 'cost' => 0.000005 } }
  end

  def call_client(data = response, &block)
    transport = block || ->(**_) { { status: 200, body: JSON.generate(data) } }
    Ai::JevClient.new(provider: 'openrouter', api_key: 'synthetic', transport: transport)
                 .call(state: { conversation: 'Synthetic context' }, questions: questions, model: 'typesafe/jev-1.14')
  end

  it 'uses the existing OpenRouter key on the decisions-compatible System One endpoint' do
    calls = []
    result = call_client do |**args|
      calls << args
      { status: 200, body: JSON.generate(response) }
    end
    expect(calls.size).to eq(1)
    expect(calls.first[:uri].to_s).to eq('https://openrouter.ai/api/v1/systemone')
    expect(calls.first[:headers]['Authorization']).to eq('Bearer synthetic')
    expect(JSON.parse(calls.first[:body])['model']).to eq('typesafe/jev-1.14')
    expect(result).to include(ok: true, model: 'typesafe/jev-1.14', served_model: 'typesafe/jev-1.14-20261014', input_tokens: 100, cost_known: true, cost_usd: 0.000005)
  end

  it 'also accepts the exact requested version without a dated suffix' do
    response['model'] = 'typesafe/jev-1.14'
    expect(call_client[:ok]).to eq(true)
  end

  it 'does not treat token counts as known billing without provider cost' do
    response['usage'].delete('cost')
    expect(call_client).to include(ok: false, reason: 'invalid_provider_schema', usage_known: true, input_tokens: 100, cost_known: false, cost_usd: nil)
  end

  it 'preserves known billing even when answers or the served model are invalid' do
    response['model'] = 'typesafe/jev-1.15'
    expect(call_client).to include(ok: false, input_tokens: 100, cost_known: true, cost_usd: 0.000005)
  end

  it 'rejects negative, string and missing prices instead of assuming zero' do
    [-1, '0.1', nil].each do |cost|
      response['usage']['cost'] = cost
      expect(call_client).to include(ok: false, cost_known: false, cost_usd: nil)
    end
  end

  it 'does not accept aliases, chat models or unknown providers' do
    client = Ai::JevClient.new(provider: 'openrouter', transport: ->(**_) { raise 'must not call' })
    %w[~typesafe/jev-latest typesafe/jev-router openai/chat].each do |model|
      expect(client.call(state: {}, questions: questions, model: model)).to include(ok: false, reason: 'unsupported_model', cost_known: true, cost_usd: 0)
    end
  end

  it 'leaves requests disabled despite configured key when authorization is absent' do
    client = Ai::JevClient.new(provider: 'openrouter', api_key: 'synthetic')
    expect(client.call(state: {}, questions: questions, model: 'typesafe/jev-1.14')).to include(reason: 'live_requests_disabled', cost_known: true, cost_usd: 0)
    expect(WebMock).not_to have_requested(:post, Ai::JevClient::OPENROUTER_ENDPOINT.to_s)
  end

  it 'keeps timeout cost unknown and performs no automatic retry' do
    calls = 0
    result = call_client do |**_|
      calls += 1
      raise Net::ReadTimeout
    end
    expect(result).to include(ok: false, usage_known: false, cost_known: false, cost_usd: nil)
    expect(calls).to eq(1)
  end
end
