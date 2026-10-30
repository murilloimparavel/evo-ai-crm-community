require 'rails_helper'
require_relative '../../support/followup_engine_fixtures'

RSpec.describe 'Native CRM deletion with followup history' do
  include FollowupEngineFixtures
  before do
    travel_to Time.utc(2026, 11, 2, 15)
    allow(SendReplyJob).to receive(:perform_later)
  end
  after { travel_back }

  def classification(business)
    state = FollowupConversationState.for!(business[:conversation])
    FollowupClassification.create!(followup_campaign: business[:campaign], conversation: business[:conversation], source_incoming_message_id: business[:incoming].id, generation: state.classification_generation, revision: state.revision, policy_version: 'v1', model: 'jev-1.14.0', question_version: 'synthetic-v1', expires_at: 10.minutes.from_now)
  end

  def reserve_unknown_cost(business)
    offline_followup_budget.reserve!(subject: business[:execution], campaign: business[:campaign])
  end

  it 'deletes an existing card while preserving its evidence, execution and unknown billing' do
    business = build_followup_business
    reservation = reserve_unknown_cost(business)
    expect { business[:item].destroy! }.not_to raise_error
    expect(business[:execution].reload.pipeline_item_id).to be_nil
    expect(business[:evidence].reload.pipeline_item_id).to be_nil
    expect(FollowupExecution.exists?(business[:execution].id)).to eq(true)
    expect(FollowupBudgetReservation.find(reservation.id).status).to eq('reserved')
    expect(reservation.followup_budget_day.reload.reserved_usd).to eq(reservation.reserved_usd)
    expect { Followups::EvaluateJob.perform_now(business[:execution].id) }.not_to raise_error
    expect(business[:execution].reload.status).to eq('cancelled')
  end

  it 'deletes conversation runtime state, nulls historical links and leaves queued jobs harmless' do
    business = build_followup_business
    row = classification(business)
    reservation = reserve_unknown_cost(business)
    # Native pipeline cleanup already runs before a conversation deletion; the
    # existing pipeline_items FK remains outside this additive engine change.
    business[:item].destroy!
    expect { business[:conversation].destroy! }.not_to raise_error
    expect(FollowupConversationState.where(conversation_id: business[:conversation].id)).to be_empty
    expect(row.reload.conversation_id).to be_nil
    expect(business[:execution].reload.conversation_id).to be_nil
    expect(business[:evidence].reload.conversation_id).to be_nil
    expect { Followups::ClassificationRetryJob.perform_now(row.id) }.not_to raise_error
    expect { Followups::SchedulerJob.perform_now }.not_to raise_error
    expect(FollowupBudgetReservation.exists?(reservation.id)).to eq(true)
  end

  it 'deletes a public anchor without deleting the ledger or allowing evaluation' do
    business = build_followup_business
    reservation = reserve_unknown_cost(business)
    expect { business[:anchor].destroy! }.not_to raise_error
    expect(business[:evidence].reload.anchor_message_id).to be_nil
    expect(business[:execution].reload.quote_anchor_message_id).to be_nil
    classifier = double('must not classify')
    expect(classifier).not_to receive(:classify)
    evaluate_followup(business, classifier: classifier)
    expect(business[:execution].reload.status).to eq('cancelled')
    expect(FollowupBudgetReservation.exists?(reservation.id)).to eq(true)
  end

  it 'deletes an incoming source and safely retires its classification and debounce deadline' do
    business = build_followup_business
    row = classification(business)
    state = FollowupConversationState.for!(business[:conversation])
    state.update!(latest_incoming_message_id: business[:incoming].id, classification_due_at: Time.current)
    generation = state.classification_generation
    expect { business[:incoming].destroy! }.not_to raise_error
    expect(row.reload.source_incoming_message_id).to be_nil
    expect { Followups::DebouncedClassificationJob.perform_now(business[:conversation].id, generation) }.not_to raise_error
    expect(state.reload.classification_due_at).to be_nil
    Followups::ClassificationRetryJob.perform_now(row.id)
    expect(row.reload.status).to eq('cancelled')
  end

  it 'does not recreate a deleted outgoing outbox or disable its campaign as an identity incident' do
    business = build_followup_business
    evaluate_followup(business)
    message = business[:execution].reload.message
    expect { message.destroy! }.not_to raise_error
    expect(business[:execution].reload.message_id).to be_nil
    expect { Followups::ReconcileJob.perform_now }.not_to change(Message, :count)
    expect(business[:execution].reload.status).to eq('cancelled')
    expect(business[:campaign].reload.enabled).to eq(true)
  end

  it 'quarantines dispatch in progress after target deletion and guards the shared sender' do
    business = build_followup_business
    evaluate_followup(business)
    message = business[:execution].reload.message
    claim = Followups::DispatchGuard.claim(message: message)
    expect(claim).not_to be_nil
    business[:anchor].destroy!
    expect { SendReplyJob.perform_now(message.id) }.not_to raise_error
    Followups::ReconcileJob.perform_now
    expect(business[:execution].reload.status).to eq('delivery_unknown')
    expect(business[:campaign].reload.enabled).to eq(true)
    expect(Followups::DispatchGuard.preflight(claim: claim, message: message)).to eq(false)
  end
end
