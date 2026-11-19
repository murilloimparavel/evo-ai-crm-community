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

  it 'persists the activity and runs conversation_updated automation for an authenticated status change' do
    rule = AutomationRule.new(
      name: "status-activity-#{SecureRandom.hex(4)}",
      event_name: 'conversation_updated',
      active: true,
      mode: 'simple',
      conditions: [{
        attribute_key: 'status', filter_operator: 'equal_to', query_operator: '', values: ['resolved']
      }],
      actions: []
    )
    rule.save!(validate: false)

    perform_enqueued_jobs(only: [Conversations::ActivityMessageJob, EventDispatcherJob]) do
      post "/api/v1/conversations/#{conversation.display_id}/toggle_status",
           params: { status: 'resolved' }, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(conversation.reload.status).to eq('resolved')

    activity = conversation.messages.where(message_type: :activity).where.not(activity_event_id: nil)
                             .order(created_at: :desc).first!
    expect(activity.private).to be(false)
    expect(activity.content).to include(user.name)
    status_change = activity.content_attributes.fetch('status_change')
    expect(activity.activity_event_id).to eq(status_change.fetch('event_id'))
    expect(status_change.fetch('from')).to eq('open')
    expect(status_change.fetch('to')).to eq('resolved')
    expect(status_change.dig('actor', 'type')).to eq('user')
    expect(status_change.dig('actor', 'id')).to eq(user.id)
    expect(AutomationRuleRun.where(automation_rule: rule, status: 'matched')).to exist
  end
end
