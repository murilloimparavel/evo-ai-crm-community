# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# Upload, Facebook callbacks and global search must be permission-gated:
# uploads demand conversations.attachments; the Facebook channel callbacks
# demand the inbox grant matching their effect (create/read/update); each
# search surface demands the read grant of the resource it queries, and the
# 'all' search demands every one of them.
RSpec.describe 'Upload, callbacks and search RBAC', type: :request do
  let(:user) { User.create!(name: 'Perm Probe', email: "probe-#{SecureRandom.hex(4)}@example.com") }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
  end

  after { Current.reset }

  def grant_permissions(*granted)
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_service, _user_id, permission|
      granted.include?(permission)
    end
  end

  describe 'POST /api/v1/upload' do
    it 'denies a user without conversations.attachments' do
      grant_permissions('conversations.read', 'contacts.read')

      post '/api/v1/upload', params: { external_url: 'http://files.test/a.png' }, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'uploads a file for a user with conversations.attachments' do
      grant_permissions('conversations.attachments')
      file = Tempfile.new(['upload', '.txt'])
      file.write('hello')
      file.rewind

      post '/api/v1/upload', params: { attachment: Rack::Test::UploadedFile.new(file.path, 'text/plain') }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig('data', 'blob_key')).to be_present
    ensure
      file.close!
    end
  end

  describe '/api/v1/callbacks' do
    it 'denies register_facebook_page without inboxes.create' do
      grant_permissions('inboxes.read', 'inboxes.update')

      post '/api/v1/callbacks/register_facebook_page',
           params: { page_id: 'pg', inbox_name: 'FB' }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(Channel::FacebookPage.count).to eq(0)
    end

    it 'denies facebook_pages without inboxes.read' do
      grant_permissions('inboxes.create', 'inboxes.update')

      post '/api/v1/callbacks/facebook_pages', as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'denies reauthorize_page without inboxes.update' do
      grant_permissions('inboxes.read', 'inboxes.create')

      post '/api/v1/callbacks/reauthorize_page', params: { inbox_id: 0 }, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'passes the gates with the matching inbox grants' do
      grant_permissions('inboxes.read', 'inboxes.create', 'inboxes.update')

      post '/api/v1/callbacks/register_facebook_page',
           params: { page_id: 'pg', inbox_name: 'FB' }, as: :json
      expect(response).not_to have_http_status(:forbidden)

      post '/api/v1/callbacks/facebook_pages', as: :json
      expect(response).not_to have_http_status(:forbidden)

      post '/api/v1/callbacks/reauthorize_page', params: { inbox_id: 0 }, as: :json
      expect(response).not_to have_http_status(:forbidden)
    end
  end

  describe '/api/v1/search' do
    context 'with only contacts.read' do
      before { grant_permissions('contacts.read') }

      it 'allows contact search and denies the other surfaces' do
        get '/api/v1/search/contacts', params: { q: 'john' }
        expect(response).to have_http_status(:ok)

        get '/api/v1/search/conversations', params: { q: 'john' }
        expect(response).to have_http_status(:forbidden)

        get '/api/v1/search/messages', params: { q: 'john' }
        expect(response).to have_http_status(:forbidden)

        get '/api/v1/search', params: { q: 'john' }
        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'with only conversations.read' do
      before { grant_permissions('conversations.read') }

      it 'allows conversation and message search and denies the rest' do
        get '/api/v1/search/conversations', params: { q: 'john' }
        expect(response).to have_http_status(:ok)

        get '/api/v1/search/messages', params: { q: 'john' }
        expect(response).to have_http_status(:ok)

        get '/api/v1/search/contacts', params: { q: 'john' }
        expect(response).to have_http_status(:forbidden)

        get '/api/v1/search', params: { q: 'john' }
        expect(response).to have_http_status(:forbidden)
      end
    end

    it 'allows the all-surfaces search with both read grants' do
      grant_permissions('contacts.read', 'conversations.read')

      get '/api/v1/search', params: { q: 'john' }

      expect(response).to have_http_status(:ok)
    end

    it 'searches globally by a partial phone number' do
      grant_permissions('contacts.read', 'conversations.read')
      channel = Channel::WebWidget.create!(website_url: 'https://search.example.com')
      inbox = Inbox.create!(name: 'Search Spec Inbox', channel: channel)
      user.inbox_members.create!(inbox: inbox)
      contact = Contact.create!(name: 'Phone Search Contact', phone_number: '+155557381234')
      contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8))
      conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)

      get '/api/v1/search', params: { q: '5738' }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('payload', 'contacts')).to include(hash_including('id' => contact.id))

      get '/api/v1/search/conversations', params: { q: '5738' }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('payload', 'conversations'))
        .to include(hash_including('id' => conversation.id))
    end
  end
end
