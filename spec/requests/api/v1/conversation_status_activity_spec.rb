# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Conversation status activity', type: :request do
  include ActiveJob::TestHelper

  let(:user) { User.create!(name: 'Status Agent', email: "status-request-#{SecureRandom.hex(4)}@example.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://status-request.example.com') }
  let(:inbox) { Inbox.create!(name: 'Status Request Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Status Request Contact') }
  let(:contact_inbox) do
    ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(4))
  end
  let(:conversation) do
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :open)
  end

  before do
    actor = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do # rubocop:disable RSpec/AnyInstance
      Current.user = actor
      Current.evo_can_read_all_inboxes = true
      Current.evo_permission_cache ||= {}
      true
    end
    allow(EvoExtensionPoints::PermissionResolver).to receive(:allowed?).and_return(true)
  end

  after { Current.reset }

  let(:rule) do
    AutomationRule.new(
      name: "status-activity-#{SecureRandom.hex(4)}",
      event_name: 'conversation_updated',
      active: true,
      mode: 'simple',
      conditions: [{
        attribute_key: 'status', filter_operator: 'equal_to', query_operator: '', values: ['resolved']
      }],
      actions: []
    )
  end

  before do
    rule.save!(validate: false)
    perform_status_change
  end

  it 'returns success for an authenticated status change' do
    expect(response).to have_http_status(:ok)
  end

  it 'updates the conversation status' do
    expect(conversation.reload.status).to eq('resolved')
  end

  it 'persists an activity message for the status change' do
    expect(status_activity).to have_attributes(private: false, content: include(user.name))
  end

  it 'stores the actor and transition metadata on the activity message' do
    metadata = status_activity.content_attributes.fetch('status_change')
    expected_metadata = {
      'event_id' => status_activity.activity_event_id,
      'from' => 'open',
      'to' => 'resolved',
      'actor' => { 'type' => 'user', 'id' => user.id, 'name' => user.name }
    }

    expect(metadata).to include(expected_metadata)
  end

  it 'runs the matching conversation_updated automation' do
    expect(AutomationRuleRun.where(automation_rule: rule, status: 'matched')).to exist
  end

  def perform_status_change
    perform_enqueued_jobs(only: [Conversations::ActivityMessageJob, EventDispatcherJob]) do
      post "/api/v1/conversations/#{conversation.display_id}/toggle_status",
           params: { status: 'resolved' }, as: :json
    end
  end

  def status_activity
    conversation.messages
                .where(message_type: :activity)
                .where.not(activity_event_id: nil)
                .order(created_at: :desc)
                .first
  end
end
