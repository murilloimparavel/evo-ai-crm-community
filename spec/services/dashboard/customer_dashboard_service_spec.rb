# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Dashboard::CustomerDashboardService do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://dashboard.example.com') }
  let(:inbox) { Inbox.create!(name: 'Dashboard test', channel: channel) }
  let(:contact) { Contact.create!(name: 'Dashboard contact', email: "dashboard-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:range_start) { Time.zone.today - 2.days }
  let(:service) do
    described_class.new(
      params: { since: range_start.beginning_of_day.to_i, until: Time.zone.today.end_of_day.to_i }
    )
  end

  it 'builds daily conversation counts across the selected range, including days with no records' do
    first = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    last_contact = Contact.create!(
      name: 'Second contact', email: "dashboard-#{SecureRandom.hex(4)}@test.com"
    )
    last_contact_inbox = ContactInbox.create!(inbox: inbox, contact: last_contact, source_id: SecureRandom.hex(8))
    last = Conversation.create!(inbox: inbox, contact: last_contact, contact_inbox: last_contact_inbox)
    first.update!(created_at: range_start.beginning_of_day + 10.hours)
    last.update!(created_at: Time.zone.today.beginning_of_day + 10.hours)

    daily = service.send(:daily_metric, Conversation.where(id: [first.id, last.id]), :created_at, :count)

    expect(daily.keys).to eq((range_start..Time.zone.today).to_a)
    expect(daily.values).to eq([1, 0, 1])
  end

  it 'builds daily response averages across the selected range, using zero for days without events' do
    first = ReportingEvent.create!(name: 'first_response', value: 20)
    second = ReportingEvent.create!(name: 'first_response', value: 40)
    first.update!(created_at: range_start.beginning_of_day + 10.hours)
    second.update!(created_at: range_start.beginning_of_day + 12.hours)

    daily = service.send(
      :daily_metric,
      ReportingEvent.where(id: [first.id, second.id]),
      :created_at,
      :average,
      :value
    )

    expect(daily.keys).to eq((range_start..Time.zone.today).to_a)
    expect(daily.values).to eq([30, 0, 0])
  end
end
