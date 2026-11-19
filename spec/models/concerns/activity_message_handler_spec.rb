# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivityMessageHandler do
  let(:user) { User.create!(name: 'Status Agent', email: "status-agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://status-activity.example.com') }
  let(:inbox) { Inbox.create!(name: 'Status Activity Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Status Contact', email: "status-contact-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) do
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :open)
  end

  around do |example|
    Current.reset
    example.run
  ensure
    Current.reset
  end

  before do
    # These specs cover status activity generation, not downstream event delivery.
    allow(EventDispatcherJob).to receive(:perform_later).and_return(
      instance_double(ActiveJob::Base, successfully_enqueued?: true, job_id: 'dispatcher-job')
    )
  end

  def capture_activity_jobs
    jobs = []
    allow(Conversations::ActivityMessageJob).to receive(:perform_later) do |_record, params|
      jobs << params
      instance_double(ActiveJob::Base, successfully_enqueued?: true, job_id: SecureRandom.uuid)
    end
    jobs
  end

  it 'enqueues an activity for a real status transition with the human actor and transition metadata' do
    Current.user = user
    jobs = capture_activity_jobs

    conversation.update!(status: :resolved)

    message_params = jobs.fetch(0)
    expect(message_params[:message_type]).to eq(:activity)
    expect(message_params[:content]).to include(user.name)
    expect(message_params.dig(:content_attributes, :status_change)).to eq(
      event_id: message_params[:activity_event_id],
      from: 'open', to: 'resolved', actor: { type: 'user', id: user.id, name: user.name },
      execution_source: 'User'
    )
    expect(message_params.dig(:content_attributes, :activity_event)).to include(
      event_id: message_params[:activity_event_id],
      action: 'status_changed',
      actor: hash_including(type: 'user', id: user.id.to_s, name: user.name),
      target: { type: 'conversation', id: conversation.id.to_s },
      changes: { from: 'open', to: 'resolved' }
    )
  end

  it 'attributes an AutomationRule status change to the system' do
    rule = AutomationRule.create!(
      name: "Rule #{SecureRandom.hex(3)}",
      event_name: 'conversation_updated',
      conditions: [],
      actions: [],
      active: true
    )
    Current.executed_by = rule
    jobs = capture_activity_jobs

    conversation.update!(status: :resolved)

    message_params = jobs.fetch(0)
    expect(message_params[:content]).to include(I18n.t('automation.system_name'))
    expect(message_params.dig(:content_attributes, :status_change)).to eq(
      event_id: message_params[:activity_event_id],
      from: 'open', to: 'resolved',
      actor: { type: 'automation', id: rule.id, name: I18n.t('automation.system_name') },
      execution_source: 'AutomationRule'
    )
  end

  it 'uses a system actor for an unrecognized execution source instead of dropping the activity' do
    Current.executed_by = :stage_automation
    jobs = capture_activity_jobs

    conversation.update!(status: :resolved)

    message_params = jobs.fetch(0)
    expect(message_params[:content]).to include(I18n.t('automation.system_name'))
    expect(message_params.dig(:content_attributes, :status_change)).to eq(
      event_id: message_params[:activity_event_id],
      from: 'open', to: 'resolved',
      actor: { type: 'system', id: nil, name: I18n.t('automation.system_name') },
      execution_source: 'stage_automation'
    )
  end

  it 'does not enqueue a duplicate activity when the status is already set' do
    capture_activity_jobs
    expect(Conversations::ActivityMessageJob).not_to receive(:perform_later)

    conversation.update!(status: :open)
  end

  it 'records the actor and assignee for assignment and removal activities' do
    Current.user = user
    jobs = capture_activity_jobs

    conversation.update!(assignee: user)
    conversation.update!(assignee: nil)

    expect(jobs.map { |params| params.dig(:content_attributes, :activity_event, :action) }).to eq(
      %w[assignee_assigned assignee_removed]
    )
    assigned = jobs.first.dig(:content_attributes, :activity_event)
    expect(assigned[:actor]).to include(type: 'user', id: user.id.to_s, name: user.name)
    expect(assigned[:target]).to include(type: 'user', id: user.id.to_s, name: user.name)
    expect(jobs.map { |params| params[:activity_event_id] }.uniq.size).to eq(2)
  end

  it 'records team changes and priority changes with structured targets and values' do
    Current.user = user
    jobs = capture_activity_jobs
    team = Team.create!(name: 'Activity Audit Team')

    conversation.update!(team: team)
    conversation.update!(team: nil)
    conversation.update!(priority: :urgent)

    events = jobs.map { |params| params.dig(:content_attributes, :activity_event) }
    expect(events.map { |event| event[:action] }).to include('team_assigned', 'team_removed', 'priority_changed')
    expect(events.find { |event| event[:action] == 'team_assigned' }[:target]).to include(
      type: 'team', id: team.id.to_s, name: team.name
    )
    expect(events.find { |event| event[:action] == 'priority_changed' }[:changes]).to eq(from: 0, to: 3)
  end

  it 'logs a rejected enqueue instead of claiming success' do
    job = instance_double(ActiveJob::Base, successfully_enqueued?: false, job_id: 'rejected-job')
    fallback_message = instance_double(Message, id: 'fallback-message')
    allow(Conversations::ActivityMessageJob).to receive(:perform_later).and_return(job)
    expect(Conversations::ActivityMessageJob).to receive(:perform_now).with(
      conversation,
      hash_including(message_type: :activity, content: a_string_including(I18n.t('automation.system_name')))
    ).and_return(fallback_message)
    expect(Rails.logger).to receive(:error).with(a_string_including('status_change_enqueue_rejected'))

    conversation.update!(status: :resolved)
  end
end
