# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::InstagramEventsJob, type: :job do
  it 'updates the existing inbound message and records the previous text' do
    channel = instance_double(Channel::Instagram)
    original = double('Message', incoming?: true, content: 'before', content_attributes: {})
    relation = instance_double(ActiveRecord::Relation)
    allow(Message).to receive(:joins).with(:inbox).and_return(relation)
    allow(relation).to receive(:where).with(source_id: 'mid-1', inboxes: { channel: channel }).and_return(relation)
    allow(relation).to receive(:first).and_return(original)
    expect(original).to receive(:update!).with(
      content: 'after', content_attributes: { 'is_edited' => true, 'previous_content' => 'before' }
    )

    described_class.new.send(:message_edit, { message_edit: { mid: 'mid-1', text: 'after' } }.with_indifferent_access, channel)
  end

  it 'resolves the channel from the entry id when message_edit has no sender or recipient' do
    job = described_class.new
    job.instance_variable_set(:@entries, [{ id: 'ig-account-1', messaging: [{ message_edit: { mid: 'mid-1', text: 'after' } }] }])
    expect(job.send(:sender_id)).to eq('ig-account-1')
    expect(job.send(:instagram_id, { message_edit: { mid: 'mid-1', text: 'after' } }.with_indifferent_access,
                    { id: 'ig-account-1' }.with_indifferent_access)).to eq('ig-account-1')
  end
end
