# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::ActivityMessageJob, type: :job do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://activity-job.example.com') }
  let(:inbox) { Inbox.create!(name: 'Activity Job Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Activity Job Contact') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:event_id) { SecureRandom.uuid }

  it 'persists a status activity only once when the same job is retried' do
    params = {
      inbox_id: inbox.id,
      message_type: :activity,
      content: 'Conversation was marked resolved by Agent',
      activity_event_id: event_id,
      content_attributes: {
        status_change: { event_id: event_id, from: 'open', to: 'resolved' }
      }
    }

    first = described_class.perform_now(conversation, params)
    retry_result = described_class.perform_now(conversation, params)

    expect(retry_result.id).to eq(first.id)
    expect(conversation.messages.where(activity_event_id: event_id).count).to eq(1)
  end
end
