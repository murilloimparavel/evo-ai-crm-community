# frozen_string_literal: true

require 'rails_helper'

# Every AI feature is registered here, and the
# resolver reads this map instead of each consumer carrying its own rule.
RSpec.describe Ai::ConsumerCompatibility do
  it 'registers the six AI features of the CRM' do
    expect(described_class::CONSUMERS.keys).to contain_exactly(
      :ai_agents, :inbox_assist, :audio_transcription, :label_suggestion, :moderation, :pipeline_classification
    )
  end

  it 'lets AI Agents use every provider' do
    expect(described_class.accepted_providers(:ai_agents)).to eq(described_class::ALL_PROVIDERS)
    expect(described_class.accepts?(:ai_agents, 'anthropic')).to be(true)
    expect(described_class.accepts?(:ai_agents, 'gemini')).to be(true)
  end

  # These four build an OpenAI-shaped request (chat/completions, or Whisper for
  # transcription). A non-OpenAI provider there is a different protocol, not a
  # misconfiguration, so it must never reach the wire.
  %i[inbox_assist label_suggestion moderation].each do |consumer|
    it "restricts #{consumer} to OpenAI-compatible providers" do
      expect(described_class.accepts?(consumer, 'openai')).to be(true)
      expect(described_class.accepts?(consumer, 'azure')).to be(true)
      expect(described_class.accepts?(consumer, 'custom')).to be(true)

      expect(described_class.accepts?(consumer, 'anthropic')).to be(false)
      expect(described_class.accepts?(consumer, 'gemini')).to be(false)
      expect(described_class.accepts?(consumer, 'bedrock')).to be(false)
    end
  end

  it 'allows Groq and OpenRouter credentials only for the transcription endpoint' do
    %w[groq openrouter].each do |provider|
      expect(described_class.accepts?(:audio_transcription, provider)).to be(true)
      expect(described_class.accepts?(:inbox_assist, provider)).to be(false)
      expect(described_class.accepts?(:label_suggestion, provider)).to be(false)
      expect(described_class.accepts?(:moderation, provider)).to be(false)
    end
  end

  it 'restricts pipeline classification to the approved OpenRouter transport' do
    expect(described_class.accepted_providers(:pipeline_classification)).to eq(['openrouter'])
    expect(described_class.accepts?(:pipeline_classification, 'openai')).to be(false)
  end

  it 'rejects an unknown consumer instead of guessing' do
    expect(described_class.known?(:not_a_feature)).to be(false)
    expect(described_class.accepts?(:not_a_feature, 'openai')).to be(false)
  end

  it 'accepts string or symbol consumers' do
    expect(described_class.known?('inbox_assist')).to be(true)
    expect(described_class.accepts?('inbox_assist', 'openai')).to be(true)
  end
end
