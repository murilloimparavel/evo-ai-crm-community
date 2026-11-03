# frozen_string_literal: true

require 'rails_helper'

RSpec.describe KnowledgeRuntime::DispatchIdentity do
  let(:conversation_id) { '11111111-1111-4111-8111-111111111111' }
  let(:inbox_id) { '22222222-2222-4222-8222-222222222222' }
  let(:bot_id) { '33333333-3333-4333-8333-333333333333' }
  let(:message_ids) { %w[44444444-4444-4444-8444-444444444444 55555555-5555-4555-8555-555555555555] }
  let(:conversation) { instance_double(Conversation, id: conversation_id, inbox_id: inbox_id) }
  let(:assignments) { double }
  let(:messages) { double }
  let(:valid_message) { instance_double(Message, incoming?: true, private?: false) }
  let(:arguments) { { display_id: 42, bot_id: bot_id, message_ids: message_ids } }

  before do
    allow(Conversation).to receive(:find_by).with(display_id: 42).and_return(conversation)
    allow(AgentBotInbox).to receive(:where).with(inbox_id: inbox_id, status: :active).and_return(assignments)
    allow(assignments).to receive(:limit).with(2).and_return(assignments)
    allow(assignments).to receive(:to_a).and_return([instance_double(AgentBotInbox, agent_bot_id: bot_id)])
    allow(Message).to receive(:where).with(id: message_ids, conversation_id: conversation_id, inbox_id: inbox_id).and_return(messages)
    allow(messages).to receive(:to_a).and_return([valid_message, valid_message])
  end

  it 'derives the canonical UUID from the conversation record for a debounced batch' do
    identity = described_class.resolve(**arguments)
    expect(identity.conversation_id).to eq(conversation_id)
    expect(identity.message_ids).to eq(message_ids)
    expect(identity).to be_frozen
    expect(identity.message_ids).to be_frozen
  end

  it 'denies missing, repeated and non-UUID source IDs' do
    [[], [message_ids.first, message_ids.first], ['bogus']].each do |ids|
      expect { described_class.resolve(**arguments, message_ids: ids) }.to raise_error(described_class::Denied)
    end
  end

  it 'denies missing conversation and mismatched or ambiguous bot assignments' do
    allow(Conversation).to receive(:find_by).and_return(nil)
    expect { described_class.resolve(**arguments) }.to raise_error(described_class::Denied)
    allow(Conversation).to receive(:find_by).and_return(conversation)
    [[], [instance_double(AgentBotInbox, agent_bot_id: SecureRandom.uuid)],
     [instance_double(AgentBotInbox, agent_bot_id: bot_id), instance_double(AgentBotInbox, agent_bot_id: bot_id)]].each do |rows|
      allow(assignments).to receive(:to_a).and_return(rows)
      expect { described_class.resolve(**arguments) }.to raise_error(described_class::Denied)
    end
  end

  it 'denies foreign, outgoing and private messages in the batch' do
    [[valid_message], [valid_message, instance_double(Message, incoming?: false, private?: false)],
     [valid_message, instance_double(Message, incoming?: true, private?: true)]].each do |rows|
      allow(messages).to receive(:to_a).and_return(rows)
      expect { described_class.resolve(**arguments) }.to raise_error(described_class::Denied)
    end
  end
end
