# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::SerializationData do
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: "Serialization #{SecureRandom.hex(4)}", channel: channel) }
  let(:contact) { Contact.create!(name: 'Serialization contact') }
  let(:user) do
    User.create!(email: "serialization-#{SecureRandom.hex(6)}@example.com", name: 'Serialization User')
  end
  let(:contact_inbox) do
    ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8))
  end
  let(:conversation) do
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                         agent_last_seen_at: 1.day.ago)
  end

  describe '.unread_counts_for' do
    it 'counts only incoming unread messages newer than the agent last seen time' do
      unread = Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming,
                               content: 'new unread')
      old = Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming,
                            content: 'old')
      read = Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming,
                             content: 'read', content_attributes: { 'read' => true })
      outgoing = Message.create!(inbox: inbox, conversation: conversation, message_type: :outgoing,
                                 content: 'outgoing')
      unread.update!(created_at: 2.hours.ago)
      old.update!(created_at: 2.days.ago)
      read.update!(created_at: 1.hour.ago)
      outgoing.update!(created_at: 1.hour.ago)
      conversation.update!(agent_last_seen_at: 1.day.ago)

      expect(described_class.unread_counts_for([conversation.id])).to eq(conversation.id => 1)
    end
  end

  describe '.last_non_activity_messages_for' do
    it 'returns the latest non-activity message and preloads its sender and attachments' do
      Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming,
                      content: 'older', created_at: 3.hours.ago)
      latest = Message.create!(inbox: inbox, conversation: conversation, message_type: :outgoing,
                               sender: user, content: 'latest', created_at: 2.hours.ago)
      Message.create!(inbox: inbox, conversation: conversation, message_type: :activity,
                      content: 'activity', created_at: 1.hour.ago)

      result = described_class.last_non_activity_messages_for([conversation.id])

      expect(result[conversation.id]).to eq(latest)
      expect(result[conversation.id].association(:sender)).to be_loaded
      expect(result[conversation.id].association(:attachments)).to be_loaded
    end
  end

  it 'returns empty maps without querying for empty IDs' do
    expect(ActiveRecord::Base.connection).not_to receive(:exec_query)

    expect(described_class.unread_counts_for([])).to eq({})
    expect(described_class.last_non_activity_messages_for([])).to eq({})
  end
end
