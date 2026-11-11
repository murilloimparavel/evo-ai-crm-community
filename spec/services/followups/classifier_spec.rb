# frozen_string_literal: true

require 'spec_helper'
require 'active_support/all'
require_relative '../../../app/services/ai/jev_client'
require_relative '../../../app/services/followups/question_validator'
require_relative '../../../app/services/followups/decision_rules'
require_relative '../../../app/services/followups/templates'
require_relative '../../../app/services/followups/classifier'

# Decision rules and the classifier are separate contracts exercised by this classifier specification.
# rubocop:disable RSpec/MultipleDescribes
RSpec.describe Followups::Classifier do
  # rubocop:enable RSpec/MultipleDescribes
  subject(:classifier) { described_class.new(client: client) }

  let(:question) do
    { 'type' => 'choice', 'instructions' => 'Who must act next in the public conversation?',
      'criteria' => { 'customer' => 'Customer is choosing', 'business' => 'Business owes an answer',
                      'unclear' => 'Insufficient evidence' }, 'min_confidence' => 0.8 }
  end
  let(:policy) do
    {
      'timezone' => 'Europe/Lisbon', 'classifier' => {
        'model' => 'jev-1.14.0', 'question_version' => 'clinic-v1',
        'questions' => { 'owner' => question },
        'conditions' => [{
          'action' => 'send',
          'reason' => 'customer_choosing', 'template_id' => 'approved-clinic-template',
          'when' => { 'question' => 'owner', 'field' => 'choice', 'op' => 'eq', 'value' => 'customer' }
        }]
      }
    }
  end
  let(:snapshot) do
    { state: { 'messages' => [{ 'role' => 'customer', 'content' => 'I am deciding' }] },
      references: { anchor_message_id: 'approved-anchor' }, valid_until: Time.current + 120 }
  end
  let(:answer) do
    { 'type' => 'choice', 'choice' => 'customer', 'confidence' => 0.97,
      'probabilities' => { 'customer' => 0.98, 'business' => 0.01, 'unclear' => 0.01 } }
  end
  let(:client) { instance_double(Ai::JevClient) }
  let(:response) do
    { ok: true, model: 'jev-1.14.0', answers: { 'owner' => answer }, input_tokens: 170, usage_known: true, retryable: false, retry_after: nil }
  end

  before do
    allow(client).to receive(:call).and_return(response)
    allow(Followups::Templates).to receive(:fetch).with('approved-clinic-template').and_return(id: 'approved-clinic-template', version: '1',
                                                                                               content: 'Any questions about scheduling?')
  end

  it 'combines typed independent answers in code and returns an approved DB template ID' do
    expect(classifier.classify(snapshot: snapshot,
                               policy: policy)).to include(action: 'send', reason: 'customer_choosing',
                                                           template_id: 'approved-clinic-template', input_tokens: 170,
                                                           usage_known: true, question_version: 'clinic-v1')
    expect(client).to have_received(:call).once
  end

  it 'is reusable for another stage, business and timezone using DB configuration' do
    policy['timezone'] = 'Asia/Tokyo'
    policy['classifier']['question_version'] = 'workshop-v2'
    question['instructions'] = 'Who must act next to arrange a repair?'
    result = classifier.classify(snapshot: snapshot, policy: policy)
    expect(result).to include(action: 'send', question_version: 'workshop-v2')
    expect(client).to have_received(:call)
      .with(hash_including(questions: hash_including('owner' => hash_including('instructions' => question['instructions']))))
  end

  it 'can classify without an anchor but cannot authorize a send' do
    snapshot[:references][:anchor_message_id] = nil
    snapshot[:classification_only] = true
    expect(classifier.classify(snapshot: snapshot,
                               policy: policy)).to include(action: 'abstain', reason: 'observation_only', input_tokens: 170, proposed_action: 'send',
                                                           classification: hash_including('owner' => hash_including('choice' => 'customer')))
    expect(client).to have_received(:call).once
  end

  it 'abstains on unclear and low confidence' do
    answer['choice'] = 'unclear'
    expect(classifier.classify(snapshot: snapshot, policy: policy)[:action]).to eq('abstain')
    answer['choice'] = 'customer'
    answer['confidence'] = 0.79
    expect(classifier.classify(snapshot: snapshot, policy: policy)[:action]).to eq('abstain')
  end

  it 'never uses an unapproved or changed template' do
    allow(Followups::Templates).to receive(:fetch).and_return(nil)
    expect(classifier.classify(snapshot: snapshot, policy: policy)).to include(action: 'abstain', reason: 'template_not_approved')
  end

  it 'validates configuration before invoking any provider' do
    question['criteria'].delete('unclear')
    expect(classifier.classify(snapshot: snapshot, policy: policy)).to include(action: 'abstain', reason: 'invalid_classifier_configuration')
    expect(client).not_to have_received(:call)
  end

  it 'rejects actions and arbitrary executable paths in the DSL' do
    rule = policy['classifier']['conditions'].first
    rule['when'] = { 'question' => 'owner', 'field' => 'choice', 'op' => 'system', 'value' => 'customer' }
    expect(classifier.classify(snapshot: snapshot, policy: policy)[:action]).to eq('abstain')
    expect(client).not_to have_received(:call)
  end

  it 'lets a blocking condition override a matching send regardless of order' do
    policy['classifier']['conditions'] << { 'action' => 'block', 'reason' => 'needs_internal_review',
                                            'when' => { 'any' => [policy['classifier']['conditions'].first['when']] } }
    expect(classifier.classify(snapshot: snapshot, policy: policy)).to include(action: 'block', reason: 'needs_internal_review', template_id: nil)
  end

  it 'uses Noul probability directly and abstains in the configured uncertain band' do
    policy['classifier']['questions']['stop'] =
      { 'type' => 'noul', 'instructions' => 'Explicit stop?', 'criteria' => { 'true' => 'Stop', 'false' => 'No stop' }, 'yes_threshold' => 0.85,
        'no_threshold' => 0.1 }
    response[:answers]['stop'] = { 'type' => 'noul', 'noul' => 0.5 }
    expect(classifier.classify(snapshot: snapshot, policy: policy)).to include(action: 'abstain', reason: 'uncertain_answer')
    response[:answers]['stop']['noul'] = 0.99
    policy['classifier']['conditions'] << { 'action' => 'block', 'reason' => 'stop_contact',
                                            'when' => { 'question' => 'stop', 'field' => 'noul', 'op' => 'gte', 'value' => 0.85 } }
    expect(classifier.classify(snapshot: snapshot, policy: policy)).to include(action: 'block', reason: 'stop_contact')
  end

  it 'fails closed for timeout and retains unknown billing usage' do
    response.replace(ok: false, model: 'jev-1.14.0', reason: 'classification_timeout', input_tokens: nil, usage_known: false, retryable: true)
    expect(classifier.classify(snapshot: snapshot,
                               policy: policy)).to include(action: 'abstain', reason: 'classification_timeout',
                                                           usage_known: false, input_tokens: nil, retryable: true)
  end

  it 'does not call a provider with an expired or unbounded snapshot' do
    snapshot[:valid_until] = Time.current - 1
    expect(classifier.classify(snapshot: snapshot, policy: policy)[:action]).to eq('abstain')
    expect(client).not_to have_received(:call)
  end

  it 'rejects an oversized structured request without truncation or a call' do
    snapshot[:state]['messages'][0]['content'] = 'é' * 9000
    expect(classifier.classify(snapshot: snapshot, policy: policy)).to include(action: 'abstain', reason: 'snapshot_too_large')
    expect(client).not_to have_received(:call)
  end
end

RSpec.describe Followups::DecisionRules do
  let(:questions) { { 'level' => { 'type' => 'score', 'criteria' => %w[Low Medium High] } } }

  it 'supports Score ranges beyond a 0..1 probability' do
    rule = { 'action' => 'block', 'reason' => 'urgent', 'when' => { 'question' => 'level', 'field' => 'score', 'op' => 'gte', 'value' => 1.5 } }
    expect(described_class.new(conditions: [rule], questions: questions).call('level' => { 'score' => 1.7 })).to include(action: 'block')
  end

  it 'rejects unbounded, empty or excessively nested boolean expressions' do
    empty = { 'action' => 'block', 'reason' => 'empty', 'when' => { 'all' => [] } }
    expect { described_class.new(conditions: [empty], questions: questions) }.to raise_error(described_class::Invalid)
    node = { 'question' => 'level', 'field' => 'score', 'op' => 'gte', 'value' => 1 }
    6.times { node = { 'all' => [node] } }
    expect { described_class.new(conditions: [empty.merge('when' => node)], questions: questions) }.to raise_error(described_class::Invalid)
  end

  it 'rejects a mismatched numeric type rather than coercing it' do
    rule = { 'action' => 'block', 'reason' => 'urgent', 'when' => { 'question' => 'level', 'field' => 'score', 'op' => 'gte', 'value' => '1.5' } }
    expect { described_class.new(conditions: [rule], questions: questions) }.to raise_error(described_class::Invalid)
  end
end
