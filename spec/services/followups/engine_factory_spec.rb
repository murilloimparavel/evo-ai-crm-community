require 'rails_helper'
require_relative '../../support/followup_engine_fixtures'

# This integration scenario spans the scheduler, classifier, evidence and dispatch contracts.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Followup classifier authorization factory' do
  # rubocop:enable RSpec/DescribeClass
  include FollowupEngineFixtures
  before do
    travel_to Time.utc(2026, 11, 2, 15, 0, 0)
    allow(SendReplyJob).to receive(:perform_later)
  end

  it 'constructs the live adapter only after a complete gated budget reservation' do
    business = build_followup_business(live_ready: true)
    budget = Followups::Budget.new(settings: { online_enabled: true, budget_timezone: 'UTC', daily_usd: 1.0, daily_conversations: 20 })
    expect(budget.live_authorized?).to be(false)
    fake_client = instance_double(Ai::JevClient)
    fake_classifier = instance_double(
      Followups::Classifier, classify: fake_followup_result(business)
    )
    expect(budget).to receive(:reserve!).ordered.and_call_original
    expect(Ai::JevClient).to receive(:new).with(live_authorized: true).ordered.and_return(fake_client)
    expect(Followups::Classifier).to receive(:new).with(client: fake_client).ordered.and_return(fake_classifier)
    Followups::Evaluator.new(subject: business[:execution], snapshot_builder: instance_double(Followups::SnapshotBuilder,
                                                                                              call: fake_followup_snapshot), budget: budget).call
    expect(business[:execution].reload.status).to eq('queued')
    expect(budget.live_authorized?).to be(true)
  end

  it 'never constructs a client when installation online approval is OFF' do
    business = build_followup_business(live_ready: true)
    budget = Followups::Budget.new(settings: { online_enabled: false, budget_timezone: 'UTC', daily_usd: 1.0, daily_conversations: 20 })
    expect(Ai::JevClient).not_to receive(:new)
    Followups::Evaluator.new(subject: business[:execution], snapshot_builder: instance_double(Followups::SnapshotBuilder,
                                                                                              call: fake_followup_snapshot), budget: budget).call
    expect(business[:execution].reload.reason).to eq('online_not_authorized')
    expect(budget.live_authorized?).to be(false)
  end

  it 'never authorizes a real adapter from an offline test budget' do
    business = build_followup_business
    budget = offline_followup_budget
    budget.reserve!(subject: business[:execution], campaign: business[:campaign])
    expect(budget.live_authorized?).to be(false)
  end

  it 'reloads a persisted hot OFF after the Budget object was constructed' do
    business = build_followup_business(live_ready: true)
    settings = InstallationConfig.create!(name: 'FOLLOWUP_SETTINGS',
                                          value: { online_enabled: true, budget_timezone: 'UTC',
                                                   daily_usd: 1.0, daily_conversations: 20 })
    budget = Followups::Budget.new
    settings.update!(value: settings.value.merge('online_enabled' => false))
    expect do
      budget.reserve!(subject: business[:execution], campaign: business[:campaign])
    end.to raise_error(Followups::Budget::Exceeded, 'online_not_authorized')
    expect(budget.live_authorized?).to be(false)
  end

  it 'rechecks a lower budget ceiling after snapshot work before constructing a client' do
    business = build_followup_business(live_ready: true)
    settings = InstallationConfig.create!(name: 'FOLLOWUP_SETTINGS',
                                          value: { online_enabled: true, budget_timezone: 'UTC',
                                                   daily_usd: 1.0, daily_conversations: 20 })
    builder = instance_double(Followups::SnapshotBuilder)
    allow(builder).to receive(:call) do
      settings.update!(value: settings.value.merge('daily_usd' => 0.0001))
      fake_followup_snapshot
    end
    expect(Ai::JevClient).not_to receive(:new)
    Followups::Evaluator.new(subject: business[:execution], snapshot_builder: builder, budget: Followups::Budget.new).call
    expect(business[:execution].reload.reason).to eq('online_authorization_changed')
    expect(FollowupBudgetReservation.sole.status).to eq('settled')
    expect(FollowupBudgetReservation.sole.actual_usd).to eq(0)
  end

  it 'does not release a newer evaluation claim when a stale worker fails' do
    business = build_followup_business
    execution = business[:execution]
    classifier = instance_double(Followups::Classifier)
    allow(classifier).to receive(:classify) do
      # Inject persisted stale test state without callbacks so the safety rejection is exercised.
      # rubocop:disable Rails/SkipsModelValidations
      execution.reload.update_columns(fence_token: execution.fence_token + 1, lease_expires_at: 30.seconds.from_now)
      # rubocop:enable Rails/SkipsModelValidations
      raise IOError, 'synthetic lost classifier response'
    end
    evaluate_followup(business, classifier: classifier)
    expect(execution.reload.status).to eq('evaluating')
    expect(FollowupConversationState.for!(business[:conversation]).active_execution_id).to eq(execution.id)
  end
end
