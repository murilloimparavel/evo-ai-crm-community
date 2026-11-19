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

  describe '.conversation_updated' do
    let(:attributes) { {} }
    let(:target) { instance_double(Conversation) }

    it 'locks a separate instance so the callback retains its saved status change' do
      allow(conversation).to receive_messages(id: 'conversation-id', saved_changes: { 'status' => %w[open resolved] },
                                              saved_change_to_label_list?: false)
      allow(Conversation).to receive(:find_by).with(id: 'conversation-id').and_return(target)
      expect(PipelineClassification::Lifecycle).to receive(:invalidate!).with(conversation: target, reason: 'conversation_changed')

      described_class.conversation_updated(conversation)
    end

    it 'uses a separate instance for classification context changes' do
      allow(conversation).to receive_messages(id: 'conversation-id', saved_changes: { 'custom_attributes' => [{}, { 'x' => 1 }] },
                                              saved_change_to_label_list?: false)
      allow(Conversation).to receive(:find_by).with(id: 'conversation-id').and_return(target)
      expect(PipelineClassification::Lifecycle).to receive(:context_changed!).with(conversation: target)

      described_class.conversation_updated(conversation)
    end
  end
end
