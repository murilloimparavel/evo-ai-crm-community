require 'rails_helper'
require 'database_cleaner/active_record'
require_relative '../../support/followup_engine_fixtures'

# Keep the existing integration spec path used by the release regression suites.
# rubocop:disable RSpec/SpecFilePathFormat
RSpec.describe Followups::CircuitBreaker do
  # rubocop:enable RSpec/SpecFilePathFormat
  include FollowupEngineFixtures
  self.use_transactional_tests = false

  around do |example|
    cleaner = DatabaseCleaner[:active_record]
    cleaner.strategy = :truncation
    cleaner.cleaning { example.run }
  end

  before do
    travel_to Time.utc(2026, 11, 2, 15)
    allow(SendReplyJob).to receive(:perform_later)
  end

  def state
    InstallationConfig.find_by!(name: described_class::NAME).value
  end

  def provider_success(business, reason: 'customer_deciding')
    fake_followup_result(business, reason: reason).merge(classification: {
                                                           'next_owner' => {
                                                             'type' => 'choice', 'choice' => 'customer', 'confidence' => 1.0,
                                                             'probabilities' => { 'customer' => 1.0, 'company' => 0.0, 'unclear' => 0.0 }
                                                           }
                                                         })
  end

  it 'persists consecutive provider errors and closes until the configured cooldown' do
    business = build_followup_business
    breaker = described_class.new
    4.times { breaker.record(result: { reason: 'classification_timeout' }, campaign: business[:campaign]) }
    expect(described_class.new.check!).to be(true)
    breaker.record(result: { reason: 'provider_http_529' }, campaign: business[:campaign])
    expect(state['consecutive_failures']).to eq(5)
    expect { described_class.new.check! }.to raise_error(described_class::Open, 'provider_circuit_open')
    travel 301.seconds
    expect(described_class.new.check!).to be(true)
  end

  it 'never clears an authentication pause from an in-flight success or elapsed cooldown' do
    business = build_followup_business
    breaker = described_class.new
    breaker.record(result: { reason: 'provider_http_401' }, campaign: business[:campaign])
    breaker.record(result: provider_success(business), campaign: business[:campaign])
    travel 1.day
    expect { described_class.new.check! }.to raise_error(described_class::Open, 'provider_manual_reset_required')
    allow(business[:user]).to receive(:has_permission?).with('installation_configs.manage').and_return(false)
    expect { breaker.reset!(actor: business[:user]) }.to raise_error(described_class::Open, 'provider_reset_operator_required')
    allow(business[:user]).to receive(:has_permission?).with('installation_configs.manage').and_return(true)
    expect(breaker.reset!(actor: business[:user])).to be(true)
    expect(described_class.new.check!).to be(true)
    expect(state['reset_by_user_id']).to eq(business[:user].id)
  end

  it 'resets failures for a typed semantic abstention but not local OFF or malformed answers' do
    business = build_followup_business
    breaker = described_class.new
    breaker.record(result: { reason: 'classification_transport_error' }, campaign: business[:campaign])
    breaker.record(result: fake_followup_result(business, action: 'abstain', reason: 'live_requests_disabled'), campaign: business[:campaign])
    expect(state['consecutive_failures']).to eq(1)
    malformed = provider_success(business).merge(classification: { 'next_owner' => { 'type' => 'choice', 'choice' => 'invented' } })
    breaker.record(result: malformed, campaign: business[:campaign])
    expect(state['consecutive_failures']).to eq(1)
    breaker.record(result: provider_success(business, reason: 'uncertain_answer').merge(action: 'abstain'), campaign: business[:campaign])
    expect(state['consecutive_failures']).to eq(0)
  end

  it 'shares the authentication stop with offline budget paths before any additional reservation' do
    business = build_followup_business
    described_class.new.record(result: { reason: 'provider_http_401' }, campaign: business[:campaign])
    classifier = instance_double(Followups::Classifier)
    expect(classifier).not_to receive(:classify)
    evaluate_followup(business, classifier: classifier)
    expect(business[:execution].reload.reason).to eq('provider_manual_reset_required')
    expect(FollowupBudgetReservation.count).to eq(0)
  end

  it 'preserves unknown billing and suppresses the retry after the error opens the circuit' do
    business = build_followup_business
    InstallationConfig.create!(name: 'FOLLOWUP_SETTINGS', value: { 'circuit_failure_threshold' => 1, 'circuit_cooldown_seconds' => 300 })
    classifier = instance_double(
      Followups::Classifier, classify: fake_followup_result(business, action: 'abstain',
                                                                      reason: 'classification_timeout', usage_known: false,
                                                                      input_tokens: nil, retryable: true, retry_after: 5)
    )
    evaluate_followup(business, classifier: classifier)
    reservation = FollowupBudgetReservation.sole
    expect(reservation.status).to eq('reserved')
    travel 6.seconds
    evaluate_followup(business, classifier: classifier)
    expect(classifier).to have_received(:classify).once
    expect(business[:execution].reload.reason).to eq('provider_circuit_open')
    expect(reservation.reload.status).to eq('reserved')
    expect(FollowupBudgetReservation.count).to eq(1)
  end

  it 'fails closed for invalid circuit settings' do
    expect do
      described_class.new(settings: { circuit_failure_threshold: 0 }).check!
    end.to raise_error(described_class::Open,
                       'provider_circuit_configuration_invalid')
    expect do
      described_class.new(settings: { circuit_cooldown_seconds: '300' }).check!
    end.to raise_error(described_class::Open,
                       'provider_circuit_configuration_invalid')
  end

  it 'serializes concurrent failures without losing increments' do
    business = build_followup_business
    described_class.new.record(result: { reason: 'classification_timeout' }, campaign: business[:campaign])
    workers = Array.new(3) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.new.record(result: { reason: 'invalid_provider_schema' }, campaign: business[:campaign])
        end
      end
    end
    workers.each do |worker|
      expect(worker.join(5)).not_to be_nil
      worker.value
    end
    expect(state['consecutive_failures']).to eq(4)
  end
end
