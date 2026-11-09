# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ai::ModelResolver do
  it 'uses the OpenRouter model setting instead of the unrelated OpenAI model' do
    expect(described_class.resolve(
             'whisper-large-v3',
             provider: 'openrouter',
             openrouter_model: 'anthropic/claude-sonnet'
           ))
      .to eq('anthropic/claude-sonnet')
  end

  it 'removes the OpenRouter routing prefix copied from model selectors' do
    expect(described_class.resolve(
             'gpt-4.1-nano',
             provider: 'openrouter',
             openrouter_model: 'openrouter/openai/gpt-4.1-nano'
           ))
      .to eq('openai/gpt-4.1-nano')
  end

  it 'adds the OpenAI vendor for bare OpenRouter model names' do
    expect(described_class.resolve('gpt-4.1-nano', provider: 'openrouter', openrouter_model: 'gpt-4.1-nano'))
      .to eq('openai/gpt-4.1-nano')
  end

  it 'leaves models unchanged for other providers' do
    expect(described_class.resolve('whisper-large-v3', provider: 'groq', openrouter_model: 'gpt-4.1'))
      .to eq('whisper-large-v3')
  end
end
