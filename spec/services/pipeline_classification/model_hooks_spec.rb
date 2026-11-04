require 'rails_helper'

RSpec.describe PipelineClassification::ModelHooks do
  let(:conversation) { instance_double(Conversation) }
  let(:message) do
    instance_double(Message, imported?: true, private?: false, incoming?: true, outgoing?: false,
                             failed?: false,
                             conversation_id: 'conversation-id', content_attributes: attributes)
  end

  before do
    allow(described_class).to receive(:ready?).and_return(true)
    allow(Conversation).to receive(:find_by).with(id: message.conversation_id).and_return(conversation)
  end

  context 'with a live Stays Bridge message' do
    let(:attributes) { { 'external_created_at' => '2026-11-04T12:00:00Z' } }

    it 'routes imported channel events into the classifier lifecycle' do
      expect(PipelineClassification::Lifecycle).to receive(:incoming!).with(conversation: conversation, message: message)

      described_class.message_created(message)
    end
  end

  context 'with a historical imported message' do
    let(:attributes) { {} }

    it 'does not open a new classification cycle' do
      expect(PipelineClassification::Lifecycle).not_to receive(:incoming!)

      described_class.message_created(message)
    end
  end
end
