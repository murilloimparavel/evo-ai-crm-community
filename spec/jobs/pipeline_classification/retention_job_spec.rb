require 'rails_helper'

RSpec.describe PipelineClassification::RetentionJob, type: :job do
  it 'deletes terminal history past retention and preserves unknown in-flight charges' do # rubocop:disable RSpec/ExampleLength
    owner = User.create!(name: 'Retention owner', email: "retention-#{SecureRandom.hex(5)}@example.test")
    pipeline = Pipeline.create!(name: "Retention #{SecureRandom.hex(5)}", created_by: owner)
    InstallationConfig.create!(name: 'PIPELINE_CLASSIFICATION_SETTINGS', value: { 'retention_days' => 30 })
    attributes = {
      pipeline: pipeline, generation: 1, revision: 1, catalog_hash: 'a' * 64,
      model: PipelineClassification::Catalog::MODEL, question_version: 'pipeline_stage_v1', status: 'abstained'
    }
    expired = PipelineClassificationResult.create!(attributes.merge(reason: 'uncertain_answer', created_at: 31.days.ago))
    retained = PipelineClassificationResult.create!(attributes.merge(reason: 'uncertain_answer', created_at: 2.days.ago))
    unknown_charge = PipelineClassificationResult.create!(attributes.merge(reason: 'provider_error', created_at: 31.days.ago))
    day = PipelineClassificationBudgetDay.create!(scope_key: 'installation', budget_date: Date.current, timezone: 'UTC',
                                                  reserved_usd: 0.01, spent_usd: 0, conversation_ids: [], conversation_count: 0)
    PipelineClassificationBudgetReservation.create!(pipeline_classification_budget_day: day,
                                                    pipeline_classification_result: unknown_charge, attempt_number: 1,
                                                    reserved_usd: 0.01, status: 'reserved')
    expired_day = PipelineClassificationBudgetDay.create!(scope_key: 'installation', budget_date: 31.days.ago.to_date,
                                                          timezone: 'UTC', reserved_usd: 0, spent_usd: 0,
                                                          conversation_ids: [SecureRandom.uuid], conversation_count: 1)
    reserved_day = PipelineClassificationBudgetDay.create!(scope_key: 'installation', budget_date: 32.days.ago.to_date,
                                                           timezone: 'UTC', reserved_usd: 0.01, spent_usd: 0,
                                                           conversation_ids: [SecureRandom.uuid], conversation_count: 1)
    PipelineClassificationBudgetReservation.create!(pipeline_classification_budget_day: reserved_day,
                                                    pipeline_classification_result: unknown_charge, attempt_number: 2,
                                                    reserved_usd: 0.01, status: 'reserved')

    described_class.perform_now

    expect(PipelineClassificationResult.exists?(expired.id)).to be(false)
    expect(PipelineClassificationResult.exists?(retained.id)).to be(true)
    expect(PipelineClassificationResult.exists?(unknown_charge.id)).to be(true)
    expect(PipelineClassificationBudgetReservation.exists?(pipeline_classification_result_id: unknown_charge.id)).to be(true)
    expect(PipelineClassificationBudgetDay.exists?(expired_day.id)).to be(false)
    expect(PipelineClassificationBudgetDay.exists?(reserved_day.id)).to be(true)
  end
end
