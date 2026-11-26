# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::InstagramEventsJob, type: :job do
  it 'routes message_edit payloads to the edit handler' do
    channel = instance_double(Channel::Instagram)
    messaging = { message_edit: { mid: 'mid-1', text: 'after' } }.with_indifferent_access
    handler = instance_double(Instagram::MessageEditService, perform: true)
    allow(Instagram::MessageEditService).to receive(:new)
      .with(messaging: messaging, channel: channel).and_return(handler)

    expect(described_class.new.send(:event_name, messaging)).to eq(:message_edit)
    described_class.new.send(:message_edit, messaging, channel)
  end

  it 'resolves the channel from the entry id when message_edit has no sender or recipient' do
    job = described_class.new
    entries = [{ id: 'ig-account-1', messaging: [{ message_edit: { mid: 'mid-1', text: 'after' } }] }]
    job.instance_variable_set(:@entries, entries)

    expect(job.send(:sender_id)).to eq('ig-account-1')
    messaging = { message_edit: { mid: 'mid-1', text: 'after' } }.with_indifferent_access
    entry = { id: 'ig-account-1' }.with_indifferent_access
    expect(job.send(:instagram_id, messaging, entry)).to eq('ig-account-1')
  end
end
