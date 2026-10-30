require 'rails_helper'
require_relative '../../support/followup_engine_fixtures'

RSpec.describe Followups::DispatchGuard do
  include FollowupEngineFixtures
  before do
    travel_to Time.utc(2026, 11, 2, 15, 0, 0)
    allow(SendReplyJob).to receive(:perform_later)
  end
  after { travel_back }

  it 'claims the same Message only once and fences stale dispatchers' do
    business = build_followup_business
    evaluate_followup(business)
    message = business[:execution].reload.message
    first = described_class.claim(message: message)
    expect(first).not_to be_nil
    expect(described_class.claim(message: message)).to be_nil
    expect(described_class.preflight(message: message, claim: first)).to eq(true)
    stale = first.dup
    stale.fence_token -= 1
    expect(described_class.preflight(message: message, claim: stale)).to eq(false)
  end

  it 'revalidates OFF between claim and provider' do
    business = build_followup_business
    evaluate_followup(business)
    message = business[:execution].reload.message
    claim = described_class.claim(message: message)
    business[:campaign].update!(enabled: false, mode: 'off')
    expect(described_class.preflight(message: message, claim: claim)).to eq(false)
    expect(business[:execution].reload.status).to eq('cancelled')
  end

  it 'quarantines a lost dispatch lease and reconciles late delivery from failed Message' do
    business = build_followup_business
    evaluate_followup(business)
    message = business[:execution].reload.message
    described_class.claim(message: message)
    travel 91.seconds
    Followups::ReconcileJob.perform_now
    expect(business[:execution].reload.status).to eq('delivery_unknown')
    message.update_columns(status: Message.statuses[:failed], source_id: 'synthetic-provider-id')
    expect(Followups::DeliveryTracker.status_changed(message: message.reload, status: 'delivered', provider_id: 'synthetic-provider-id')).to eq(true)
    expect(business[:execution].reload.status).to eq('delivered')
    expect(Followups::DeliveryTracker.status_changed(message: message, status: 'sent', provider_id: 'synthetic-provider-id')).to eq(false)
    expect(business[:execution].reload.status).to eq('delivered')
  end

  it 'reuses the outbox for a 429 and refuses retry after incoming cancellation' do
    business = build_followup_business
    evaluate_followup(business)
    message = business[:execution].reload.message
    claim = described_class.claim(message: message)
    expect(Followups::DeliveryTracker.rate_limited(message: message, claim: claim, retry_at: 1.second.from_now)).to eq(true)
    expect(described_class.claim(message: message)).to be_nil
    Followups::Cancellation.invalidate(conversation: business[:conversation], reason: 'opt_out')
    travel 2.seconds
    expect(described_class.claim(message: message)).to be_nil
    expect(business[:execution].reload.message_id).to eq(message.id)
  end
end
