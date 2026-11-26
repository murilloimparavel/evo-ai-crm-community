# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Instagram::MessageEditService do
  it 'updates the matching inbound message and preserves the previous text' do
    channel = instance_double(Channel::Instagram)
    original = instance_double(Message, incoming?: true, content: 'before', content_attributes: {})
    relation = instance_double(ActiveRecord::Relation)
    allow(Message).to receive(:joins).with(:inbox).and_return(relation)
    allow(relation).to receive(:find_by).with(source_id: 'mid-1', inboxes: { channel: channel }).and_return(original)
    expect(original).to receive(:update!).with(
      content: 'after',
      content_attributes: { 'is_edited' => true, 'previous_content' => 'before' }
    )

    described_class.new(
      messaging: { message_edit: { mid: 'mid-1', text: 'after' } }.with_indifferent_access,
      channel: channel
    ).perform
  end

  it 'does not modify an outgoing message' do
    channel = instance_double(Channel::Instagram)
    outgoing = instance_double(Message, incoming?: false)
    relation = instance_double(ActiveRecord::Relation)
    allow(Message).to receive(:joins).with(:inbox).and_return(relation)
    allow(relation).to receive(:find_by).and_return(outgoing)

    expect(outgoing).not_to receive(:update!)
    described_class.new(
      messaging: { message_edit: { mid: 'mid-1', text: 'after' } }.with_indifferent_access,
      channel: channel
    ).perform
  end
end
