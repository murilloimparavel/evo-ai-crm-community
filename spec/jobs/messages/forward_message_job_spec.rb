require 'rails_helper'

RSpec.describe Messages::ForwardMessageJob, type: :job do
  let(:source_message) do
    instance_double(
      Message,
      private?: false,
      activity?: false,
      template?: false,
      content_attributes: content_attributes
    )
  end
  let(:content_attributes) { {} }
  let(:source_conversation) { instance_double(Conversation, messages: source_messages) }
  let(:source_messages) { instance_double(ActiveRecord::Relation) }
  let(:inbox) { instance_double(Inbox, channel_type: 'Channel::Whatsapp') }
  let(:contact) { instance_double(Contact, phone_number: '+5511999999999') }
  let(:user) { instance_double(User) }

  before do
    allow(Conversation).to receive(:find).with('conversation-1').and_return(source_conversation)
    allow(source_messages).to receive(:find).with('message-1').and_return(source_message)
    allow(Inbox).to receive(:find).with('inbox-1').and_return(inbox)
    allow(Contact).to receive(:find).with('contact-1').and_return(contact)
    allow(User).to receive(:find).with('user-1').and_return(user)
  end

  describe 'eligibility recheck at delivery time' do
    it 'does not forward a message deleted after it was queued' do
      allow(source_message).to receive(:content_attributes).and_return({ 'deleted' => true })

      expect(ContactInboxBuilder).not_to receive(:new)
      expect do
        described_class.perform_now('conversation-1', 'message-1', 'contact-1', 'inbox-1', 'user-1')
      end.not_to raise_error
    end

    it 'does not forward a message revoked by the contact after it was queued' do
      allow(source_message).to receive(:content_attributes).and_return({ 'revoked_by_contact' => true })

      expect(ContactInboxBuilder).not_to receive(:new)
      expect do
        described_class.perform_now('conversation-1', 'message-1', 'contact-1', 'inbox-1', 'user-1')
      end.not_to raise_error
    end
  end
end
