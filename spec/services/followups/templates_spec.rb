# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Followups::Templates do
  let(:reviewer) { User.create!(name: 'Template reviewer', email: "reviewer-#{SecureRandom.hex(5)}@example.test") }
  let(:template) do
    body = 'Would you like help choosing an appointment?'
    FollowupTemplate.create!(template_key: "clinic-#{SecureRandom.hex(4)}", version: '1', body: body,
                             body_digest: Digest::SHA256.hexdigest(body), approved_by: reviewer, approved_at: Time.current, active: true)
  end

  it 'fetches the approved version and content from the database' do
    expect(described_class.fetch(template.id, version: '1')).to eq(id: template.id, version: '1', content: template.body)
    expect(described_class.fetch(template.id, version: '2')).to be_nil
  end

  it 'fails closed when a previously approved body changes' do
    template.update_columns(body: 'Unreviewed change')
    expect(described_class.fetch(template.id)).to be_nil
  end

  it 'fails closed for an inactive or unapproved version' do
    template.update_columns(active: false)
    expect(described_class.fetch(template.id)).to be_nil
    template.update_columns(active: true, approved_by_id: nil)
    expect(described_class.fetch(template.id)).to be_nil
  end
end
