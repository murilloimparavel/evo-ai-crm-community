require 'rails_helper'
require_relative '../../support/followup_engine_fixtures'

RSpec.describe 'Shared billing ledger for OpenRouter decisions' do
  include FollowupEngineFixtures

  it 'records authoritative USD cost once instead of deriving it from tokens' do
    business = build_followup_business
    budget = offline_followup_budget
    reservation = budget.reserve!(subject: business[:execution], campaign: business[:campaign])
    response = { usage_known: true, input_tokens: 10, cost_known: true, cost_usd: 0.0001 }
    2.times { budget.settle!(reservation, response) }
    expect(reservation.reload.actual_usd).to eq(BigDecimal('0.0001'))
    expect(reservation.followup_budget_day.reload.spent_usd).to eq(BigDecimal('0.0001'))
  end

  it 'keeps the reservation when provider billing is missing or invalid' do
    business = build_followup_business
    budget = offline_followup_budget
    reservation = budget.reserve!(subject: business[:execution], campaign: business[:campaign])
    [{ cost_known: false, cost_usd: nil }, { cost_known: true, cost_usd: -1 }, { cost_known: true, cost_usd: '0.1' }].each do |cost|
      budget.settle!(reservation, { usage_known: true, input_tokens: 10 }.merge(cost))
      expect(reservation.reload.status).to eq('reserved')
    end
  end
end
