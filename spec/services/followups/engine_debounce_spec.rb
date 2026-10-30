require 'rails_helper'
require_relative '../../support/followup_engine_fixtures'

# Keep the existing integration spec path used by the release regression suites.
# rubocop:disable RSpec/SpecFilePathFormat
RSpec.describe Followups::DebounceCoordinator do
  # rubocop:enable RSpec/SpecFilePathFormat
  include FollowupEngineFixtures
  before do
    travel_to Time.utc(2026, 11, 2, 15, 0, 0)
    allow(SendReplyJob).to receive(:perform_later)
    scheduled = instance_double(ActiveJob::ConfiguredJob, perform_later: nil)
    allow(Followups::DebouncedClassificationJob).to receive(:set).and_return(scheduled)
  end

  def incoming(business, content)
    message = business[:conversation].messages.create!(inbox: business[:inbox], message_type: :incoming, content: content)
    described_class.on_incoming!(message: message)
    message
  end

  # Keep the complete multi-record integration scenario and its atomic safety assertions together.
  # rubocop:disable RSpec/ExampleLength
  it 'coalesces a burst in persisted state, rejects stale jobs, and classifies once after quiet' do
    business = build_followup_business
    incoming(business, 'One')
    first_generation = FollowupConversationState.for!(business[:conversation]).classification_generation
    travel 0.5.seconds
    latest = incoming(business, 'Two')
    state = FollowupConversationState.for!(business[:conversation]).reload
    expect(state.classification_generation).to eq(first_generation + 1)
    expect(state.latest_incoming_message_id).to eq(latest.id)
    classifier = instance_double(
      Followups::Classifier, classify: fake_followup_result(business)
    )
    factory = lambda { |row|
      Followups::Evaluator.new(subject: row, classifier: classifier,
                               snapshot_builder: instance_double(Followups::SnapshotBuilder, call: fake_followup_snapshot),
                               budget: offline_followup_budget)
    }
    expect(Followups::DebouncedClassifier.new(conversation: business[:conversation], generation: first_generation,
                                              evaluator_factory: factory).call).to eq([])
    expect(Followups::DebouncedClassifier.new(conversation: business[:conversation], generation: state.classification_generation,
                                              evaluator_factory: factory).call).to eq([])
    travel 2.seconds
    # A fresh service reads the deadline from PostgreSQL, after a worker restart.
    2.times do
      Followups::DebouncedClassifier.new(conversation: business[:conversation], generation: state.classification_generation,
                                         evaluator_factory: factory).call
    end
    expect(classifier).to have_received(:classify).once
    expect(FollowupClassification.sole.status).to eq('classified')
    expect(FollowupExecution.where(conversation_id: business[:conversation].id, status: 'queued')).to be_empty
  end
  # rubocop:enable RSpec/ExampleLength

  it 'persists semantic classification without a commercial anchor or any message side effect' do
    business = build_followup_business
    latest = incoming(business, 'What is included?')
    state = FollowupConversationState.for!(business[:conversation]).reload
    travel 2.seconds
    classifier = instance_double(
      Followups::Classifier, classify: fake_followup_result(business, action: 'block',
                                                                      reason: 'company_owes_answer', template_id: nil)
    )
    factory = lambda { |row|
      Followups::Evaluator.new(subject: row, classifier: classifier,
                               snapshot_builder: instance_double(Followups::SnapshotBuilder, call: fake_followup_snapshot),
                               budget: offline_followup_budget)
    }
    expect do
      Followups::DebouncedClassifier.new(conversation: business[:conversation], generation: state.classification_generation,
                                         evaluator_factory: factory).call
    end.not_to change(Message, :count)
    expect(FollowupClassification.sole.source_incoming_message_id).to eq(latest.id)
    expect(FollowupClassification.sole.reason).to eq('company_owes_answer')
    expect(business[:item].reload.pipeline_stage_id).to eq(business[:stage].id)
  end

  # Keep the complete multi-record integration scenario and its atomic safety assertions together.
  # rubocop:disable RSpec/ExampleLength
  it 'persists fractional scores and their complete typed probability distribution' do
    business = build_followup_business
    policy = business[:campaign].policy.deep_dup
    policy['classifier']['questions'] =
      { 'readiness' => { 'type' => 'score', 'instructions' => 'Estimate readiness to decide', 'criteria' => %w[none limited moderate strong],
                         'min_confidence' => 0.7 } }
    policy['classifier']['conditions'] =
      [{ 'action' => 'send', 'reason' => 'ready_to_decide', 'template_id' => business[:template].id,
         'when' => { 'all' => [{ 'question' => 'readiness', 'field' => 'score', 'op' => 'gte', 'value' => 2 }] } }]
    business[:campaign].update!(policy: policy, policy_version: 'v2')
    incoming(business, 'I am comparing the options')
    state = FollowupConversationState.for!(business[:conversation]).reload
    travel 2.seconds
    probabilities = { '0' => 0.1, '1' => 0.1, '2' => 0.1, '3' => 0.7 }
    answer = { 'type' => 'score', 'score' => 2.4, 'confidence' => 0.8, 'probabilities' => probabilities, 'raw_text' => 'must never be persisted' }
    classifier = instance_double(
      Followups::Classifier, classify: fake_followup_result(business, action: 'abstain',
                                                                      reason: 'observation_only', template_id: nil).merge(
                                                                        classification: { 'readiness' => answer }, proposed_action: 'send'
                                                                      )
    )
    factory = lambda { |row|
      Followups::Evaluator.new(subject: row, classifier: classifier,
                               snapshot_builder: instance_double(Followups::SnapshotBuilder, call: fake_followup_snapshot),
                               budget: offline_followup_budget)
    }
    Followups::DebouncedClassifier.new(conversation: business[:conversation], generation: state.classification_generation,
                                       evaluator_factory: factory).call
    stored = FollowupClassification.sole.decision.fetch('classification').fetch('readiness')
    expect(stored).to eq('type' => 'score', 'score' => 2.4, 'confidence' => 0.8, 'probabilities' => probabilities)
  end
  # rubocop:enable RSpec/ExampleLength
end
