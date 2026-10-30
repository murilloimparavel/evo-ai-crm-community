require 'rails_helper'
require 'database_cleaner/active_record'
require 'timeout'

RSpec.describe PipelineClassification::Evaluator do
  self.use_transactional_tests = false
  around do |example|
    cleaner = DatabaseCleaner[:active_record]
    cleaner.strategy = :truncation
    cleaner.cleaning { example.run }
  end

  # Keep the complete approval/race lifecycle and its observable side effects in one regression example.
  it 'serializes competing aggregate editors and returns a conflict to the stale editor' do # rubocop:disable RSpec/ExampleLength
    user = User.create!(name: 'Synthetic owner', email: "concurrency-#{SecureRandom.hex(4)}@example.test")
    pipeline = Pipeline.create!(name: 'Concurrent catalog', created_by: user)
    PipelineStage.create!(pipeline: pipeline, name: 'Considering', position: 1)
    hash = PipelineClassification::Catalog.new(pipeline).hash
    start = Queue.new
    results = Queue.new
    threads = %w[Sales Support].map do |purpose|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          value = PipelineClassification::Catalog::DEFAULT_PROFILE.deep_dup.merge('purpose' => purpose)
          PipelineClassification::Editor.new(pipeline: Pipeline.find(pipeline.id), actor: user).save!(payload: { 'classification' => value },
                                                                                                      expected_hash: hash)
          results << :saved
        rescue PipelineClassification::Catalog::Conflict
          results << :conflict
        rescue StandardError => e
          results << e
        end
      end
    end
    2.times { start << true }
    threads.each { |thread| expect(thread.join(5)).not_to be_nil }
    values = Array.new(2) { results.pop }
    raise(values.find { |value| value.is_a?(Exception) }) if values.any?(Exception)

    expect(values).to contain_exactly(:saved, :conflict)
    expect(pipeline.reload.config.dig('classification', 'purpose')).to match(/\A(?:Sales|Support)\z/)
  ensure
    threads&.each { |thread| thread.join(5) }
  end

  # Build the real isolated catalog and conversation required by cross-connection fencing tests.
  def runtime_result # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    InstallationConfig.create!(name: 'PIPELINE_CLASSIFICATION_SETTINGS', value: { 'max_attempt_cost_usd' => 0.01 })
    InstallationConfig.create!(name: 'FOLLOWUP_SETTINGS', value: { 'budget_timezone' => 'UTC', 'daily_usd' => 1.0, 'daily_conversations' => 10 })
    user = User.create!(name: 'Worker operator', email: "worker-#{SecureRandom.hex(4)}@example.test")
    channel = Channel::WebWidget.create!(website_url: 'https://synthetic.example.test')
    inbox = Inbox.create!(name: 'Workers', channel: channel, enable_auto_assignment: false)
    contact = Contact.create!(name: 'Synthetic customer')
    binding = ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4))
    conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: binding, status: :pending)
    pipeline = Pipeline.create!(name: 'Worker catalog', created_by: user)
    stage = PipelineStage.create!(pipeline: pipeline, name: 'Considering', position: 1)
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation)
    pipeline.update!(config: { 'classification' => PipelineClassification::Catalog::DEFAULT_PROFILE.deep_dup.merge('purpose' => 'Classify intent',
                                                                                                                   'enabled' => true,
                                                                                                                   'mode' => 'observe',
                                                                                                                   'inbox_ids' => [inbox.id]) })
    stage.update!(classification_profile: PipelineClassification::Catalog::DEFAULT_STAGE.deep_dup.merge('classification_enabled' => true,
                                                                                                        'definition' =>
                    'Customer is considering options'))
    PipelineClassification::Editor.new(pipeline: pipeline.reload,
                                       actor: user).publish!(expected_hash: PipelineClassification::Catalog.new(pipeline).hash)
    conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'Show me the options')
    state = PipelineClassificationState.find_by!(pipeline: pipeline, conversation: conversation)
    PipelineClassification::DebouncedClassifier.new(state: state, generation: state.generation, now: state.due_at + 0.01).call
  end

  def typed_response(choice)
    { ok: true, model: PipelineClassification::Catalog::MODEL,
      answers: { 'stage_candidate' => { 'type' => 'choice', 'choice' => choice, 'confidence' => 1.0 } }, usage_known: true, input_tokens: 100,
      cost_known: true, cost_usd: 0.0000042 }
  end

  # Keep the complete approval/race lifecycle and its observable side effects in one regression example.
  it 'allows only one simultaneous worker to reserve budget and invoke the provider' do # rubocop:disable RSpec/ExampleLength
    row = runtime_result
    entered = Queue.new
    release = Queue.new
    calls = Queue.new
    provider = Object.new
    provider.define_singleton_method(:call) do |**_params|
      calls << true
      entered << true
      release.pop
      { ok: true, model: PipelineClassification::Catalog::MODEL,
        answers: { 'stage_candidate' => { 'type' => 'choice', 'choice' => 'stage_1', 'confidence' => 1.0 } }, usage_known: true,
        input_tokens: 100, cost_known: true, cost_usd: 0.0000042 }
    end
    worker = lambda do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.new(result: PipelineClassificationResult.find(row.id), client: provider,
                            budget: PipelineClassification::Budget.new(offline: true)).call
      end
    end
    first = Thread.new { worker.call }
    Timeout.timeout(5) { entered.pop }
    second = Thread.new { worker.call }
    expect(second.join(5)).not_to be_nil
    release << true
    expect(first.join(5)).not_to be_nil
    first.value
    second.value
    expect(calls.size).to eq(1)
    expect(FollowupBudgetReservation.where(subject: row).count).to eq(1)
    expect(row.reload.status).to eq('classified')
  ensure
    release << true if release
    [first, second].compact.each { |thread| thread.join(5) }
  end

  # Keep the complete approval/race lifecycle and its observable side effects in one regression example.
  it 'prevents an expired worker from overwriting the result owned by a newer fence' do # rubocop:disable RSpec/ExampleLength
    row = runtime_result
    entered = Queue.new
    release = Queue.new
    old_response = typed_response('stage_1')
    provider = Object.new
    provider.define_singleton_method(:call) do |**_params|
      entered << true
      release.pop
      old_response
    end
    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.new(result: PipelineClassificationResult.find(row.id), client: provider,
                            budget: PipelineClassification::Budget.new(offline: true)).call
      end
    end
    Timeout.timeout(5) { entered.pop }
    # Deliberately emulate an expired worker lease without running lifecycle callbacks.
    row.reload.update_columns(lease_expires_at: 1.second.ago) # rubocop:disable Rails/SkipsModelValidations
    replacement = instance_double(Ai::JevClient, call: typed_response('no_candidate'))
    described_class.new(result: row.reload, client: replacement, budget: PipelineClassification::Budget.new(offline: true)).call
    expect(row.reload.reason).to eq('no_candidate')
    release << true
    expect(first.join(5)).not_to be_nil
    first.value
    expect(row.reload.reason).to eq('no_candidate')
    expect(row.fence_token).to eq(2)
    expect(FollowupBudgetReservation.where(subject: row, status: 'settled').count).to eq(2)
  ensure
    release << true if release
    first&.join(5)
  end
end
