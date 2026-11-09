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

  it 'normalizes a configured OpenRouter URL with a trailing slash' do
    service = described_class.new(account: nil, event: { 'name' => 'rephrase' })
    endpoint = Ai::CredentialResolver::Endpoint.new(key: 'key', base_url: 'https://openrouter.ai/api/v1/',
                                                     provider: 'openrouter')
    allow(Ai::CredentialResolver).to receive(:resolve_endpoint).and_return(endpoint)

    expect(service.send(:api_url)).to eq('https://openrouter.ai/api/v1')
  end

  it 'returns an explicit configuration error when no credential exists' do
    service = described_class.new(account: nil, event: { 'name' => 'rephrase' })
    endpoint = Ai::CredentialResolver::Endpoint.new(key: nil, base_url: nil, provider: nil)
    allow(Ai::CredentialResolver).to receive(:resolve_endpoint).and_return(endpoint)
    allow(GlobalConfigService).to receive(:load).with('OPENAI_API_URL', nil).and_return(nil)

    expect(service.perform).to eq(
      error: { message: 'Credencial de IA não configurada.' }, error_code: 503
    )
  end

  it 'keeps sentiment analysis on the moderation credential path' do
    service = described_class.new(account: nil, event: { 'name' => 'analyze_sentiment' })
    endpoint = Ai::CredentialResolver::Endpoint.new(key: 'key', base_url: nil, provider: 'openai')
    expect(Ai::CredentialResolver).to receive(:resolve_endpoint)
      .with(for_consumer: :moderation).and_return(endpoint)

    expect(service.send(:credential_endpoint)).to eq(endpoint)
  end

  it 'returns a safe gateway error when the provider response is not valid JSON' do
    service = described_class.new(account: nil, event: { 'name' => 'rephrase', 'data' => { 'content' => 'private text' } })
    allow(service).to receive_messages(api_url: 'https://openrouter.ai/api/v1/chat/completions', api_key: 'key',
                                       gpt_model: 'openai/gpt-4.1-nano')
    response = instance_double(HTTParty::Response, code: 200, success?: true, body: 'not-json')
    allow(HTTParty).to receive(:post).and_return(response)

    expect(service.send(:make_api_call, '{}')).to eq(
      error: { message: 'O provedor de IA retornou uma resposta inválida.' }, error_code: 502
    )
  end

  it 'does not include provider response content in errors' do
    service = described_class.new(account: nil, event: { 'name' => 'rephrase' })
    allow(service).to receive_messages(api_url: 'https://openrouter.ai/api/v1/chat/completions', api_key: 'key',
                                       gpt_model: 'openai/gpt-4.1-nano')
    response = instance_double(HTTParty::Response, code: 429, success?: false)
    allow(HTTParty).to receive(:post).and_return(response)

    expect(service.send(:make_api_call, '{}')).to eq(
      error: { message: 'O provedor de IA recusou a solicitação.' }, error_code: 429
    )
  end

  it 'converts provider connection failures into a gateway error' do
    service = described_class.new(account: nil, event: { 'name' => 'rephrase' })
    allow(service).to receive_messages(api_url: 'https://openrouter.ai/api/v1/chat/completions', api_key: 'key',
                                       gpt_model: 'openai/gpt-4.1-nano')
    allow(HTTParty).to receive(:post).and_raise(SocketError, 'secret host detail')

    expect(service.send(:make_api_call, '{}')).to eq(
      error: { message: 'Não foi possível conectar ao provedor de IA.' }, error_code: 502
    )
  end
end
