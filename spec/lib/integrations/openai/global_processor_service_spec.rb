# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::Openai::GlobalProcessorService do
  it 'uses the inbox-assist credential for chat events' do
    service = described_class.new(account: nil, event: { 'name' => 'rephrase' })
    endpoint = Ai::CredentialResolver::Endpoint.new(key: 'key', base_url: nil, provider: 'openrouter')
    expect(Ai::CredentialResolver).to receive(:resolve_endpoint)
      .with(for_consumer: :inbox_assist).and_return(endpoint)

    expect(service.send(:credential_endpoint)).to eq(endpoint)
    expect(service.send(:api_url)).to eq('https://openrouter.ai/api/v1')
    allow(GlobalConfigService).to receive(:load).with('OPENROUTER_MODEL', Ai::ModelResolver::OPENROUTER_DEFAULT_MODEL)
      .and_return('anthropic/claude-sonnet')
    expect(service.send(:gpt_model)).to eq('anthropic/claude-sonnet')
  end

  it 'keeps sentiment analysis on the moderation credential path' do
    service = described_class.new(account: nil, event: { 'name' => 'analyze_sentiment' })
    endpoint = Ai::CredentialResolver::Endpoint.new(key: 'key', base_url: nil, provider: 'openai')
    expect(Ai::CredentialResolver).to receive(:resolve_endpoint)
      .with(for_consumer: :moderation).and_return(endpoint)

    expect(service.send(:credential_endpoint)).to eq(endpoint)
  end
end
