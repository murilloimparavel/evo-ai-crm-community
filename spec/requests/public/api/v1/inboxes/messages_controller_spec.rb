# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public Inbound Messages API', type: :request do
  let(:api_channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'API Inbox', channel: api_channel) }
  let(:contact) { Contact.create!(name: 'Ada Lovelace', email: "ada-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  let(:path) do
    "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}" \
      "/conversations/#{conversation.display_id}/messages"
  end

  describe 'POST create with inline content' do
    # Inbound messages always carry content and have no template alternative, so
    # the deprecated-inline-content WARN must NOT fire here — it would spam the
    # signal meant to identify legacy OUTBOUND consumers (EVO-1720 [6.11]).
    it 'creates the incoming message without the legacy deprecated-content WARN' do
      allow(Rails.logger).to receive(:warn)

      expect do
        post path, params: { content: 'hello from a contact' },
                   headers: { 'X-Client-ID' => 'legacy-consumer' }, as: :json
      end.to change(conversation.messages, :count).by(1)

      expect(response).to have_http_status(:success)
      created = conversation.messages.last
      expect(created.message_type).to eq('incoming')
      expect(created.content).to eq('hello from a contact')
      expect(Rails.logger).not_to have_received(:warn).with(/deprecated inline content/)
    end
  end

  describe 'POST import' do
    let(:bridge_token) { 'synthetic-airbnb-bridge-token-' + ('x' * 32) }
    let(:bridge_env_key) { 'STAYS_BRIDGE_AIRBNB_IMPORT_TOKEN' }
    let(:import_path) { "#{path}/import" }
    let(:bridge_headers) { { 'X-Stays-Bridge-Token' => bridge_token } }

    around do |example|
      original = ENV[bridge_env_key]
      ENV[bridge_env_key] = bridge_token
      example.run
    ensure
      original.nil? ? ENV.delete(bridge_env_key) : ENV[bridge_env_key] = original
    end

    before do
      conversation.update!(custom_attributes: { stays_bridge_managed: true, stays_channel: 'airbnb' })
    end

    let(:payload) do
      {
        content: 'reply sent outside the CRM',
        source_id: 'stays:airbnb:stable-source-id',
        message_type: 'outgoing',
        external_created_at: '2026-10-14T21:25:26.000Z'
      }
    end

    it 'persists imported direction and external timestamp and returns the message ID' do
      expect do
        post import_path, params: payload, headers: bridge_headers, as: :json
      end.to change(conversation.messages, :count).by(1)

      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      message = conversation.messages.last
      expect(json['id']).to eq(message.id)
      expect(json['message_type']).to eq('outgoing')
      expect(message).to be_imported
      expect(message).to be_outgoing
      expect(message.external_created_at).to eq(payload[:external_created_at])
      expect(message.created_at.utc.iso8601(3)).to eq(payload[:external_created_at])
    end

    it 'returns the existing message for a repeated source_id without duplicating' do
      post import_path, params: payload, headers: bridge_headers, as: :json
      first_id = response.parsed_body['id']

      expect do
        post import_path, params: payload.merge(content: 'retry after uncertain response'), headers: bridge_headers, as: :json
      end.not_to change(conversation.messages, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['id']).to eq(first_id)
      expect(conversation.messages.last.content).to eq(payload[:content])
    end

    it 'rejects unsupported message directions and missing source IDs' do
      post import_path, params: payload.merge(message_type: 'activity'), headers: bridge_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)

      post import_path, params: payload.except(:source_id), headers: bridge_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects missing and invalid bridge tokens' do
      post import_path, params: payload, as: :json
      expect(response).to have_http_status(:unauthorized)

      post import_path, params: payload, headers: { 'X-Stays-Bridge-Token' => 'invalid-token' }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects an invalid external timestamp' do
      post import_path, params: payload.merge(external_created_at: 'not-a-timestamp'), headers: bridge_headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
