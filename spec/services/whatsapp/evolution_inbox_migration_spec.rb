# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Whatsapp::EvolutionInboxMigration do
  let(:source_channel) do
    Channel::Whatsapp.create!(
      provider: 'evolution',
      phone_number: '+5511999990001',
      provider_config: { 'api_url' => 'https://evolution.example', 'admin_token' => 'test-token', 'instance_name' => 'old' }
    )
  end
  let(:target_channel) do
    Channel::Whatsapp.create!(
      provider: 'whatsapp_cloud',
      phone_number: '+5511999990002',
      provider_config: {
        'evolution_hub' => { 'channel_id' => 'hub-target', 'linked' => true },
        'waba_id' => 'test-waba'
      }
    )
  end
  let(:source_inbox) { Inbox.create!(name: 'WhatsApp Evolution', channel: source_channel) }
  let(:target_inbox) { Inbox.create!(name: 'WPP principal', channel: target_channel) }
  let(:migration) do
    described_class.new(source_inbox_id: source_inbox.id, target_inbox_id: target_inbox.id, batch_size: 1)
  end
  let(:contact) do
    Contact.create!(name: 'Cliente de teste', phone_number: '+5511988887777')
  end
  let(:source_contact_inbox) do
    ContactInbox.create!(inbox: source_inbox, contact: contact, source_id: '5511988887777')
  end
  let(:conversation) do
    Conversation.create!(inbox: source_inbox, contact: contact, contact_inbox: source_contact_inbox,
                         source: :imported, status: :open, additional_attributes: { 'kept' => true })
  end
  let(:message) do
    conversation.messages.create!(inbox: source_inbox, content: 'Histórico preservado', message_type: :incoming,
                                  source: :imported, source_id: 'evolution-message-id', sender: contact,
                                  created_at: 2.days.ago, updated_at: 2.days.ago)
  end
  let(:attachment) do
    Attachment.create!(attachable: message, file_type: :image, external_url: 'https://media.example/image.jpg')
  end
  let(:reporting_event) do
    ReportingEvent.create!(inbox: source_inbox, conversation: conversation, name: 'reply', value: 0.0)
  end

  before do
    stub_request(:get, 'https://evolution.example/').to_return(status: 200, body: '{}')
    stub_request(:get, %r{https://graph\.facebook\.com/}).to_return(status: 200, body: '{"data":[]}')
    stub_request(:post, %r{https://graph\.facebook\.com/}).to_return(status: 200, body: '{}')
    source_inbox
    target_inbox
    source_channel.update_provider_connection!('connection' => 'logged_out')
    message
    attachment
    reporting_event
  end

  describe '#preview' do
    it 'reports counts and recipient blockers without moving records' do
      plan = migration.preview

      expect(plan).to include(conversations: 1, messages: 1, attachments: 1, unaddressable_contacts: 0)
      expect(conversation.reload.inbox_id).to eq(source_inbox.id)
      expect(message.reload.inbox_id).to eq(source_inbox.id)
    end

    it 'blocks group addresses that the Cloud provider cannot use as recipients' do
      source_contact_inbox.update!(source_id: '120363025801848701@g.us')
      contact.update!(phone_number: nil)

      expect(migration.preview[:unaddressable_contacts]).to eq(1)
      expect do
        migration.migrate!(confirm_source_inbox_id: source_inbox.id, confirm_target_inbox_id: target_inbox.id)
      end.to raise_error(described_class::UnsafeMigration, /unsupported_cloud_recipient/)
    end
  end

  describe '#migrate!' do
    it 'moves existing records in place, preserving their IDs and history timestamps' do
      report = migration.migrate!(confirm_source_inbox_id: source_inbox.id, confirm_target_inbox_id: target_inbox.id)

      destination_contact_inbox = ContactInbox.find_by!(inbox_id: target_inbox.id, contact_id: contact.id)
      expect(report).to include(migrated_conversations: 1, remaining_conversations: 0)
      expect(conversation.reload).to have_attributes(inbox_id: target_inbox.id,
                                                     contact_inbox_id: destination_contact_inbox.id,
                                                     status: 'open')
      expect(conversation.additional_attributes.dig('channel_migration', 'from_inbox_id')).to eq(source_inbox.id)
      expect(message.reload).to have_attributes(inbox_id: target_inbox.id, source_id: 'evolution-message-id',
                                                content: 'Histórico preservado')
      expect(message.created_at).to be_within(1.second).of(2.days.ago)
      expect(attachment.reload.attachable_id).to eq(message.id)
      expect(reporting_event.reload.inbox_id).to eq(target_inbox.id)
      expect(source_inbox.reload.messages.count).to eq(0)
    end

    it 'refuses to operate unless both exact inbox IDs are confirmed' do
      expect do
        migration.migrate!(confirm_source_inbox_id: source_inbox.id, confirm_target_inbox_id: SecureRandom.uuid)
      end.to raise_error(described_class::UnsafeMigration, /target inbox confirmation/)
    end

    it 'refuses to operate while Evolution is connected' do
      source_channel.update_provider_connection!('connection' => 'open')

      expect do
        migration.migrate!(confirm_source_inbox_id: source_inbox.id, confirm_target_inbox_id: target_inbox.id)
      end.to raise_error(described_class::UnsafeMigration, /must be disconnected/)
    end
  end

  describe '#retire_source_inbox!' do
    it 'does not delete the source inbox before its conversations are migrated' do
      expect do
        migration.retire_source_inbox!(confirmation: source_inbox.id)
      end.to raise_error(described_class::UnsafeMigration, /still has dependent data/)

      expect(Inbox.exists?(source_inbox.id)).to be(true)
    end

    it 'requires the exact source UUID confirmation' do
      expect do
        migration.retire_source_inbox!(confirmation: 'WhatsApp Evolution')
      end.to raise_error(described_class::UnsafeMigration, /confirmation must exactly match/)
    end

    it 'retires only an empty inbox without calling the Evolution provider' do
      conversation.destroy!

      expect_any_instance_of(Whatsapp::Providers::EvolutionService).not_to receive(:disconnect_channel_provider)
      migration.retire_source_inbox!(confirmation: source_inbox.id)

      expect(Inbox.exists?(source_inbox.id)).to be(false)
      expect(Channel::Whatsapp.exists?(source_channel.id)).to be(false)
    end
  end
end
