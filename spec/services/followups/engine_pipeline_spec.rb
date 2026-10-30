require 'rails_helper'
require_relative '../../support/followup_engine_fixtures'

# This integration scenario spans the scheduler, classifier, evidence and dispatch contracts.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Modular followup pipeline' do
  # rubocop:enable RSpec/DescribeClass
  include FollowupEngineFixtures

  before do
    travel_to Time.utc(2026, 11, 2, 15, 0, 0)
    allow(SendReplyJob).to receive(:perform_later)
  end

  it 'supports distinct businesses, stage names, labels and timezones with the same engine' do
    travel = build_followup_business
    repair = build_followup_business(name: 'Repair workshop', timezone: 'Europe/Lisbon', stage_name: 'Estimate delivered',
                                     label_name: 'do_not_contact')
    [travel, repair].each do |business|
      evaluate_followup(business)
      execution = business[:execution].reload
      expect(execution.status).to eq('queued')
      expect(execution.message.content).to eq(business[:template].body)
      expect(execution.message.followup_execution_id).to eq(execution.id)
    end
    expect(travel[:campaign].policy['timezone']).not_to eq(repair[:campaign].policy['timezone'])
  end

  it 'creates one Message and performs one classification across duplicate jobs' do
    business = build_followup_business
    classifier = instance_double(
      Followups::Classifier, classify: fake_followup_result(business)
    )
    expect { 2.times { evaluate_followup(business, classifier: classifier) } }.to change(Message, :count).by(1)
    expect(classifier).to have_received(:classify).once
  end

  it 'keeps shadow evaluation independent of the writer' do
    business = build_followup_business(mode: 'shadow')
    expect(Followups::QueueService).not_to receive(:new)
    expect { evaluate_followup(business) }.not_to change(Message, :count)
    expect(business[:execution].reload.reason).to eq('shadow_no_writer')
  end

  it 'preserves the control cohort per contact and never queues its message' do
    business = build_followup_business(mode: 'pilot', cohort_percentage: 0)
    expect { evaluate_followup(business) }.not_to change(Message, :count)
    expect(business[:execution].reload.status).to eq('control')
  end

  it 'cancels the result when incoming arrives during HTTP' do
    business = build_followup_business
    classifier = instance_double(Followups::Classifier)
    allow(classifier).to receive(:classify) do
      message = business[:conversation].messages.create!(inbox: business[:inbox], message_type: :incoming, content: 'Wait, I have a question')
      Followups::DebounceCoordinator.on_incoming!(message: message)
      fake_followup_result(business)
    end
    expect { evaluate_followup(business, classifier: classifier) }.to change(Message, :count).by(1)
    expect(business[:execution].reload.status).to eq('cancelled')
    expect(business[:execution].message_id).to be_nil
  end

  it 'observes OFF changed during classification before creating outbox' do
    business = build_followup_business
    classifier = instance_double(Followups::Classifier)
    allow(classifier).to receive(:classify) do
      business[:campaign].update!(enabled: false, mode: 'off')
      fake_followup_result(business)
    end
    expect { evaluate_followup(business, classifier: classifier) }.not_to change(Message, :count)
    expect(business[:execution].reload.status).to eq('cancelled')
  end

  it 'does not treat delivered evidence or metadata approval as human takeover' do
    business = build_followup_business
    expect(business[:conversation].reload.assignee_id).to be_nil
    expect(business[:conversation].team_id).to be_nil
    expect(business[:item].reload.pipeline_stage_id).to eq(business[:stage].id)
    expect(Followups::EvidenceApproval.invalid_reason(business[:evidence])).to be_nil
    business[:anchor].update!(content: 'Edited after approval')
    expect(Followups::EvidenceApproval.invalid_reason(business[:evidence])).to eq('evidence_digest_changed')
  end

  it 'blocks human teams, optout and historical incoming before classification costs' do
    business = build_followup_business
    business[:contact].add_labels([business[:label].title])
    classifier = instance_double(Followups::Classifier)
    expect(classifier).not_to receive(:classify)
    evaluate_followup(business, classifier: classifier)
    expect(business[:execution].reload.reason).to eq('contact_changed')
    expect(FollowupBudgetReservation.count).to eq(0)
  end

  it 'blocks a renamed optout label while asynchronous tagging rename is pending' do
    business = build_followup_business
    business[:label].update!(title: "renamed_#{SecureRandom.hex(4)}")
    classifier = instance_double(Followups::Classifier)
    expect(classifier).not_to receive(:classify)
    evaluate_followup(business, classifier: classifier)
    expect(business[:execution].reload.reason).to eq('label_configuration_changed')
    expect(FollowupBudgetReservation.count).to eq(0)
  end

  %i[conversation contact].each do |target|
    it "preserves the inbox's ignored labels on #{target} even when campaign label arrays are empty" do
      business = build_followup_business(policy_label_guard: false)
      bot = AgentBot.create!(name: 'Synthetic bot', bot_config: {})
      AgentBotInbox.create!(agent_bot: bot, inbox: business[:inbox], ignored_label_ids: [business[:label].id], allowed_label_ids: [],
                            allowed_conversation_statuses: %w[pending open])
      business[target].add_labels([business[:label].title])
      expect(business[:campaign].policy['opt_out_label_ids']).to eq([])
      reason = Followups::Eligibility.new(campaign: business[:campaign], conversation: business[:conversation]).reason
      expect(reason).to eq('inbox_bot_ignored_label')
      expect(FollowupBudgetReservation.count).to eq(0)
    end
  end

  it 'fails closed for invalid policy before HTTP, and defaults new campaigns OFF' do
    business = build_followup_business
    policy = business[:campaign].policy.deep_merge('classifier' => {
                                                     'conditions' => [{
                                                       'action' => 'send', 'reason' => 'bad',
                                                       'template_id' => business[:template].id, 'when' => { 'ruby' => 'system(...)' }
                                                     }]
                                                   })
    expect(business[:campaign].update(policy: policy)).to be(false)
    fresh = FollowupCampaign.create!(campaign_key: SecureRandom.uuid, pipeline_stage: business[:stage], inbox: business[:inbox],
                                     policy_version: 'draft')
    expect(fresh.enabled).to be(false)
    expect(fresh.mode).to eq('off')
  end

  it 'reuses an unsent execution after explicit approval of a newer anchor without replaying its old state' do
    business = build_followup_business
    original_id = business[:execution].id
    anchor = business[:conversation].messages.create!(inbox: business[:inbox], message_type: :outgoing, content: 'Here are the revised options',
                                                      status: :delivered, source_id: 'synthetic-new-anchor')
    expect(business[:execution].reload.status).to eq('cancelled')
    evidence = Followups::EvidenceApproval.new(campaign: business[:campaign], conversation: business[:conversation], pipeline_item: business[:item],
                                               incoming: business[:incoming], anchor: anchor, actor: business[:user]).call
    execution = business[:execution].reload
    expect(execution.id).to eq(original_id)
    expect(execution.followup_anchor_evidence_id).to eq(evidence.id)
    expect(execution.status).to eq('reserved')
    expect(execution.message_id).to be_nil
    expect(FollowupExecution.where(conversation_id: business[:conversation].id).count).to eq(1)
  end

  it 'retains a maximum cost reservation for a request without usage' do
    business = build_followup_business
    evaluate_followup(business, result: fake_followup_result(business, action: 'abstain', reason: 'timeout', usage_known: false, input_tokens: nil))
    reservation = FollowupBudgetReservation.sole
    expect(reservation.status).to eq('reserved')
    expect(reservation.followup_budget_day.reserved_usd).to eq(reservation.reserved_usd)
    expect(reservation.followup_budget_day.spent_usd).to eq(0)
  end

  it 'honors the complete Retry-After and does not spend on an early duplicate job' do
    business = build_followup_business
    classifier = instance_double(
      Followups::Classifier, classify: fake_followup_result(business, action: 'abstain',
                                                                      reason: 'provider_rate_limited', usage_known: false,
                                                                      input_tokens: nil, retryable: true, retry_after: 300)
    )
    evaluate_followup(business, classifier: classifier)
    expect(business[:execution].reload.next_attempt_at).to eq(300.seconds.from_now)
    travel 60.seconds
    evaluate_followup(business, classifier: classifier)
    expect(classifier).to have_received(:classify).once
    expect(FollowupBudgetReservation.count).to eq(1)
  end

  it 'shares the same strict budget between shadow and active campaigns and retains unknown usage' do
    first = build_followup_business(mode: 'shadow')
    second = build_followup_business(name: 'Repair workshop', timezone: 'Europe/Lisbon', stage_name: 'Estimate delivered', label_name: 'no_contact')
    classifier = instance_double(
      Followups::Classifier, classify: fake_followup_result(first, action: 'abstain',
                                                                   reason: 'unknown_usage', usage_known: false, input_tokens: nil)
    )
    budget = offline_followup_budget(daily_usd: 0.003)
    [first, second].each do |business|
      Followups::Evaluator.new(subject: business[:execution], classifier: classifier,
                               snapshot_builder: instance_double(Followups::SnapshotBuilder, call: fake_followup_snapshot),
                               budget: budget).call
    end
    expect(classifier).to have_received(:classify).once
    expect(second[:execution].reload.reason).to eq('daily_cost_limit')
    expect(FollowupBudgetDay.sole.reserved_usd).to be > 0
  end
end
