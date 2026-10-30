require 'rails_helper'
require_relative '../../support/followup_engine_fixtures'

RSpec.describe 'Follow-up consuming the canonical pipeline classification' do
  include FollowupEngineFixtures

  before do
    travel_to Time.utc(2026, 11, 2, 15)
    allow(SendReplyJob).to receive(:perform_later)
    InstallationConfig.create!(name: 'FOLLOWUP_SETTINGS', value: { 'budget_timezone' => 'UTC', 'daily_usd' => 1.0, 'daily_conversations' => 20 })
    InstallationConfig.create!(name: 'PIPELINE_CLASSIFICATION_SETTINGS', value: { 'max_attempt_cost_usd' => 0.01 })
  end
  after { travel_back }

  def configured_business(classify: true)
    b = build_followup_business
    profile = PipelineClassification::Catalog::DEFAULT_PROFILE.deep_dup.merge(
      'purpose' => 'Classify whether the customer is considering options', 'enabled' => true, 'mode' => 'observe', 'inbox_ids' => [b[:inbox].id]
    )
    b[:pipeline].update!(config: { 'classification' => profile })
    b[:stage].update!(classification_profile: PipelineClassification::Catalog::DEFAULT_STAGE.deep_dup.merge(
      'classification_enabled' => true, 'definition' => 'Options were explained and the customer is deciding; no outstanding company answer'
    ))
    catalog = PipelineClassification::Editor.new(pipeline: b[:pipeline].reload, actor: b[:user])
    catalog.publish!(expected_hash: PipelineClassification::Catalog.new(b[:pipeline]).hash)
    PipelineClassification::Lifecycle.invalidate!(conversation: b[:conversation])
    travel 3.seconds
    state = PipelineClassificationState.find_by!(pipeline: b[:pipeline], conversation: b[:conversation])
    row = PipelineClassification::DebouncedClassifier.new(state: state, generation: state.generation).call
    if classify
      response = { ok: true, model: PipelineClassification::Catalog::MODEL,
        answers: { 'stage_candidate' => { 'type' => 'choice', 'choice' => 'stage_1', 'confidence' => 1.0, 'probabilities' => { 'stage_1' => 1.0, 'unclear' => 0.0, 'no_candidate' => 0.0 } } },
        input_tokens: 100, usage_known: true, cost_known: true, cost_usd: 0.0000042 }
      client = double('one offline pipeline decision', call: response)
      PipelineClassification::Evaluator.new(result: row, client: client, budget: PipelineClassification::Budget.new(offline: true)).call
      expect(row.reload.status).to eq('classified')
    end
    policy = b[:campaign].policy.deep_dup
    policy.delete('classifier')
    policy['classification_source'] = { 'type' => 'pipeline_catalog' }
    b[:campaign].update!(policy: policy, policy_version: 'catalog-v2')
    Followups::EvidenceApproval.new(campaign: b[:campaign], conversation: b[:conversation], pipeline_item: b[:item], incoming: b[:incoming], anchor: b[:anchor], actor: b[:user]).call
    b.merge(result: row)
  end

  it 'reuses a valid result without a second provider call or a copied question pack' do
    b = configured_business
    expect(b[:campaign].policy).not_to have_key('classifier')
    expect(Ai::DecisionClient).not_to receive(:for_pipeline)
    expect(Ai::JevClient).not_to receive(:new)
    Followups::Evaluator.new(subject: b[:execution], budget: offline_followup_budget).call
    expect(b[:execution].reload.status).to eq('queued')
    expect(b[:execution].pipeline_classification_result_id).to eq(b[:result].id)
    expect(b[:execution].classification_catalog_hash).to eq(b[:result].catalog_hash)
    expect(FollowupBudgetReservation.where(subject: b[:execution]).sole.actual_usd).to eq(0)
    expect(b[:item].reload.pipeline_stage_id).to eq(b[:stage].id)
  end

  it 'does not rearm a cancelled execution without a current recommendation despite approved evidence' do
    b = configured_business(classify: false)
    Followups::Evaluator.new(subject: b[:execution], budget: offline_followup_budget).call
    expect(b[:execution].reload.status).to eq('cancelled')
    reason = Followups::Eligibility.new(campaign: b[:campaign], conversation: b[:conversation], execution: b[:execution]).reason
    expect(reason).to eq('pipeline_classification_unavailable')
    expect(b[:execution].message_id).to be_nil
  end

  it 'rechecks the catalog before dispatch and cancels a queued message after criteria change' do
    b = configured_business
    Followups::Evaluator.new(subject: b[:execution], budget: offline_followup_budget).call
    message = b[:execution].reload.message
    expect(message).not_to be_nil
    profile = b[:stage].classification_profile.merge('definition' => 'The business must still answer a question')
    b[:stage].update!(classification_profile: profile)
    expect(Followups::DispatchGuard.claim(message: message)).to be_nil
    expect(b[:execution].reload.status).to eq('cancelled')
  end

  it 'does not accept legacy questions as a second source alongside a catalog reference' do
    policy = build_followup_business[:campaign].policy.merge('classification_source' => { 'type' => 'pipeline_catalog' })
    expect(Followups::Policy.new(policy).errors.join).to include('without duplicate classifier settings')
  end

  it 'does not rearm work after emergency OFF even when classifier configuration was removed' do
    b = build_followup_business
    b[:campaign].update!(enabled: false, mode: 'off', policy: b[:campaign].policy.except('classifier'), policy_version: 'emergency-off')
    expect(b[:campaign].classifier_config).to eq({})
    expect(Ai::JevClient).not_to receive(:new)
    Followups::Evaluator.new(subject: b[:execution], budget: offline_followup_budget).call
    expect(b[:execution].reload.status).to eq('cancelled')
    expect(FollowupBudgetReservation.where(subject: b[:execution])).to be_empty
    expect(FollowupCampaign.new(policy: { 'classification_source' => 'invalid' }).pipeline_catalog?).to eq(false)
  end
end
