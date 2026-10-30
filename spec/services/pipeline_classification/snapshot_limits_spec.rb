require 'rails_helper'

RSpec.describe PipelineClassification::SnapshotBuilder do
  def builder
    contact = double('synthetic contact')
    %i[name middle_name last_name email phone_number tax_id identifier].each { |field| allow(contact).to receive(field).and_return(nil) }
    conversation = double('synthetic conversation', inbox_id: 'inbox-id', contact: contact)
    described_class.new(result: double, catalog: double, conversation: conversation)
  end

  def message(text)
    double('synthetic public text', inbox_id: 'inbox-id', attachments: double(exists?: false),
      content_type: 'text', content_attributes: {}, content: text, incoming?: true, status: 'delivered')
  end

  it 'accepts a complete realistic quote over 800 characters without truncating its final negation' do
    text = ('opções disponíveis com condições explícitas. ' * 24) + 'Não confirmei a compra.'
    expect(text.length).to be_between(801, 2000)
    serialized = builder.send(:serialize, message(text), 0)
    expect(serialized['content']).to eq(text)
    expect(serialized['content']).to end_with('Não confirmei a compra.')
    expect(described_class::MAX_BYTES).to eq(12 * 1024)
    expect(described_class::MAX_MESSAGES).to eq(8)
  end

  it 'rejects a message above 2000 characters as a whole' do
    expect { builder.send(:serialize, message('a' * 2001), 0) }
      .to raise_error(Followups::SnapshotBuilder::Unsafe, 'snapshot_message_too_long')
  end
end
