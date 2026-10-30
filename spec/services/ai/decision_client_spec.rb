require 'rails_helper'

RSpec.describe Ai::DecisionClient do
  before { allow(Ai::Credential).to receive(:table_exists?).and_return(true) }

  def endpoint(provider: 'openrouter', base_url: 'https://openrouter.ai/api/v1', key: 'synthetic-not-a-real-key')
    Ai::CredentialResolver::Endpoint.new(provider: provider, base_url: base_url, key: key)
  end

  it 'resolves only the existing compatible credential consumer, without exposing its key' do
    expect(Ai::CredentialResolver).to receive(:resolve_endpoint).with(for_consumer: :pipeline_classification).and_return(endpoint)
    expect(described_class.status).to eq(configured: true, provider: 'openrouter')
    expect(Ai::ConsumerCompatibility.accepts?(:pipeline_classification, 'openrouter')).to be(true)
    expect(Ai::ConsumerCompatibility.accepts?(:pipeline_classification, 'openai')).to be(false)
  end

  it 'rejects a mismatched provider host and contains no key in status' do
    allow(Ai::CredentialResolver).to receive(:resolve_endpoint).and_return(endpoint(base_url: 'https://untrusted.example/api'))
    expect(described_class.status).to eq(configured: false, provider: 'openrouter')
    client = described_class.for_pipeline(model: 'typesafe/jev-1.14', live_authorized: true)
    questions = { 'x' => { 'type' => 'noul', 'instructions' => 'Condition?', 'criteria' => { 'true' => 'Yes', 'false' => 'No' } } }
    result = client.call(state: {}, questions: questions, model: 'typesafe/jev-1.14')
    expect(result[:reason]).to eq('live_requests_disabled')
  end

  it 'fails closed when the credential registry is unavailable' do
    allow(Ai::CredentialResolver).to receive(:resolve_endpoint).and_raise(ActiveRecord::StatementInvalid, 'synthetic unavailable')
    expect(described_class.status).to eq(configured: false, provider: 'openrouter')
    expect { described_class.for_pipeline(model: 'typesafe/jev-1.14') }.not_to raise_error
  end

  it 'rejects model IDs outside the supported decision adapter' do
    expect { described_class.for_pipeline(model: 'arbitrary/chat') }.to raise_error(ArgumentError, 'unsupported_decision_model')
  end
end
