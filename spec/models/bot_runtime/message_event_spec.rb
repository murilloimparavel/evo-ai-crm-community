# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotRuntime::MessageEvent do
  let(:contact) { Contact.create!(name: 'Journal Spec') }
  let(:inbox) { Inbox.create!(name: 'Journal Spec', channel: Channel::Api.create!) }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:message) { Message.new(inbox: inbox, conversation: conversation, message_type: :incoming, content: '20/11 a 23/11') }

  before do
    allow(BotRuntime::Config).to receive(:enabled?).and_return(true)
    allow(inbox).to receive(:active_bot?).and_return(true)
    allow(inbox).to receive(:agent_bot_inbox).and_return(nil)
    allow(message).to receive(:execute_after_create_commit_callbacks)
    allow(message).to receive(:publish_message_created)
    allow(message).to receive(:sync_message_event)
  end

  it 'persists the message journal before commit even when enqueue never runs' do
    message.save!
    expect(described_class.find_by(message_id: message.id)).to be_present
  end

  it 'rolls back the journal with a rolled back message' do
    Message.transaction(requires_new: true) do
      message.save!
      expect(described_class.find_by(message_id: message.id)).to be_present
      raise ActiveRecord::Rollback
    end
    expect(described_class.find_by(message_id: message.id)).to be_nil
  end

  it 'keeps moderated inboxes on the existing path' do
    allow(inbox).to receive(:agent_bot_inbox).and_return(instance_double(AgentBotInbox, moderation_enabled?: true))
    message.save!
    expect(described_class.find_by(message_id: message.id)).to be_nil
  end
end
