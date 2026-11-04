require 'rails_helper'

RSpec.describe PipelineClassification::Evaluator do
  # Build the real standalone business fixture without campaign/template shortcuts.
  def business(name: 'Sales', debounce: 2000, mode: 'observe') # rubocop:disable Metrics/AbcSize
    user = User.create!(name: 'Synthetic operator', email: "pipeline-#{SecureRandom.hex(5)}@example.test")
    channel = Channel::WebWidget.create!(website_url: 'https://synthetic.example.test')
    inbox = Inbox.create!(name: name, channel: channel, enable_auto_assignment: false)
    contact = Contact.create!(name: 'Synthetic customer', email: "client-#{SecureRandom.hex(5)}@example.test")
    binding = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(5))
    conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: binding, status: :pending)
    pipeline = Pipeline.create!(name: "#{name} #{SecureRandom.hex(5)}", created_by: user)
    stage = PipelineStage.create!(pipeline: pipeline, name: 'Considering', position: 1)
    item = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation)
    profile = PipelineClassification::Catalog::DEFAULT_PROFILE.deep_dup.merge('purpose' => "Classify #{name} intent", 'enabled' => true,
                                                                              'mode' => mode, 'inbox_ids' => [inbox.id],
                                                                              'debounce_ms' => debounce)
    stage_profile = PipelineClassification::Catalog::DEFAULT_STAGE.deep_dup.merge('classification_enabled' => true,
                                                                                  'definition' => 'Customer is considering available options')
    pipeline.update!(config: { 'classification' => profile })
    stage.update!(classification_profile: stage_profile)
    catalog = PipelineClassification::Editor.new(pipeline: pipeline.reload,
                                                 actor: user).publish!(expected_hash: PipelineClassification::Catalog.new(pipeline).hash)
    { user: user, inbox: inbox, contact: contact, conversation: conversation, pipeline: pipeline, stage: stage, item: item, catalog: catalog }
  end

  before do
    InstallationConfig.create!(name: 'PIPELINE_CLASSIFICATION_SETTINGS',
                               value: { 'online_enabled' => true, 'privacy_reviewed' => true, 'language_validated' => true,
                                        'billing_ceiling_verified' => true,
                                        'automatic_moves_enabled' => true,
                                        'retention_days' => 30, 'max_attempt_cost_usd' => 0.01,
                                        'budget_timezone' => 'UTC', 'daily_usd' => 1.0, 'daily_conversations' => 20 })
  end

  def incoming(business, text: 'Show me the available options', created_at: Time.current)
    message = business[:conversation].messages.create!(inbox: business[:inbox], message_type: :incoming, content: text, created_at: created_at)
    PipelineClassification::Lifecycle.incoming!(conversation: business[:conversation], message: message, now: created_at)
    message
  end

  def state(business)
    PipelineClassificationState.find_by!(pipeline: business[:pipeline], conversation: business[:conversation])
  end

  def due_result(business)
    row_state = state(business)
    return unless row_state.due_at

    PipelineClassification::DebouncedClassifier.new(state: row_state, generation: row_state.generation, now: row_state.due_at + 0.01).call
  end

  def response(choice: 'stage_1', confidence: 1.0, pipeline_choice: 'pipeline_1', pipeline_confidence: confidence, **overrides)
    { ok: true, model: PipelineClassification::Catalog::MODEL,
      answers: {
        'pipeline_candidate' => { 'type' => 'choice', 'choice' => pipeline_choice, 'confidence' => pipeline_confidence },
        'stage_candidate' => { 'type' => 'choice', 'choice' => choice, 'confidence' => confidence }
      }, input_tokens: 100,
      usage_known: true, cost_known: true, cost_usd: 0.0000042 }.merge(overrides)
  end

  def evaluate(row, provider_response = response, &block)
    client = instance_double(Ai::JevClient)
    allow(client).to receive(:call) do |**_params|
      block&.call
      provider_response
    end
    budget = PipelineClassification::Budget.new(offline: true)
    PipelineClassification::Evaluator.new(result: row, client: client, budget: budget).call
    client
  end

  # Keep the complete approval/race lifecycle and its observable side effects in one regression example.
  it 'classifies without any campaign, template, evidence or action and records real usage' do
    b = business
    incoming(b)
    row = due_result(b)
    expect { evaluate(row) }.not_to change(Message, :count)
    expect(row.reload.status).to eq('classified')
    expect(row.recommended_stage_id).to eq(b[:stage].id)
    expect(row.decision['financial_proof']).to be(false)
    expect(b[:item].reload.pipeline_stage_id).to eq(b[:stage].id)
    expect(PipelineClassificationBudgetReservation.where(pipeline_classification_result: row).count).to eq(1)
  end

  it 'debounces each pipeline independently and accepts equal-timestamp events by serialized order' do
    b = business(debounce: 1000)
    other = business(name: 'Support', debounce: 5000)
    other[:item].update!(conversation: b[:conversation])
    profile = other[:pipeline].config['classification'].merge('inbox_ids' => [b[:inbox].id])
    other[:pipeline].update!(config: { 'classification' => profile })
    PipelineClassification::Editor.new(pipeline: other[:pipeline],
                                       actor: other[:user]).publish!(expected_hash: PipelineClassification::Catalog.new(other[:pipeline]).hash)
    at = Time.current
    first = incoming(b, created_at: at)
    last = incoming(b, text: 'I am still deciding', created_at: at)
    expect(state(b).source_incoming_message_id).to eq(last.id)
    other_state = PipelineClassificationState.find_by!(pipeline: other[:pipeline], conversation: b[:conversation])
    expect(other_state.due_at - state(b).due_at).to be_within(0.001).of(4)
    expect(last.id).not_to eq(first.id)
    generation = state(b).generation
    PipelineClassification::Lifecycle.incoming!(conversation: b[:conversation], message: last)
    expect(state(b).generation).to eq(generation)
  end

  it 'recovers a persisted due state once and prevents duplicate provider claims' do
    b = business
    incoming(b)
    row = due_result(b)
    expect(due_result(b)).to be_nil
    first = evaluate(row)
    second = evaluate(row)
    expect(first).to have_received(:call).once
    expect(second).not_to have_received(:call)
    expect(PipelineClassificationBudgetReservation.where(pipeline_classification_result: row).count).to eq(1)
  end

  it 'preserves billed usage and invalidates a result when a new incoming arrives during HTTP' do
    b = business
    incoming(b)
    row = due_result(b)
    evaluate(row) { incoming(b, text: 'Can we discuss support instead?') }
    expect(row.reload.status).to eq('cancelled')
    expect(PipelineClassificationBudgetReservation.find_by!(pipeline_classification_result: row).status).to eq('settled')
    expect(state(b).due_at).to be_present
  end

  it 'preserves billed usage and invalidates a result when the catalog changes during HTTP' do
    b = business
    incoming(b)
    row = due_result(b)
    evaluate(row) { b[:stage].update!(name: 'Renamed stage') }
    expect(row.reload.status).to eq('cancelled')
    expect(PipelineClassificationBudgetReservation.find_by!(pipeline_classification_result: row).status).to eq('settled')
  end

  it 'abstains on unclear, insufficient confidence, unexpected model and unallowed alias' do
    [['unclear', 1.0, nil], ['stage_1', 0.2, nil], ['stage_1', 1.0, 'unexpected'],
     ['foreign_stage', 1.0, nil]].each_with_index do |(choice, confidence, model), index|
      b = business(name: "Case #{index}")
      incoming(b)
      row = due_result(b)
      evaluate(row, response(choice: choice, confidence: confidence, **(model ? { model: model } : {})))
      expect(row.reload.status).to eq('abstained')
      expect(row.recommended_stage_id).to be_nil
    end
  end

  it 'keeps no_candidate distinct from unclear' do
    b = business
    incoming(b)
    row = due_result(b)
    evaluate(row, response(choice: 'no_candidate'))
    expect(row.reload.status).to eq('classified')
    expect(row.reason).to eq('no_candidate')
    expect(row.recommended_stage_id).to be_nil
  end

  it 'classifies payment claims without treating them as financial proof' do
    b = business
    incoming(b, text: 'Já paguei o pix e enviei o comprovante')
    row = due_result(b)
    client = evaluate(row)
    expect(client).to have_received(:call).once
    expect(row.reload.status).to eq('classified')
    expect(row.decision['financial_proof']).to be(false)
  end

  it 'ignores unselected fields and invalidates selected enum/boolean changes' do
    b = business
    profile = b[:pipeline].config['classification'].deep_dup
    profile['context_sources'] =
      { 'fields' => [{ 'key' => 'interest', 'source' => 'conversation.custom_attributes', 'field' => 'interested', 'type' => 'boolean' }] }
    CustomAttributeDefinition.create!(attribute_key: 'interested', attribute_display_name: 'Interested', attribute_model: :conversation_attribute,
                                      attribute_display_type: :checkbox)
    b[:pipeline].update!(config: { 'classification' => profile })
    PipelineClassification::Editor.new(pipeline: b[:pipeline],
                                       actor: b[:user]).publish!(expected_hash: PipelineClassification::Catalog.new(b[:pipeline]).hash)
    incoming(b)
    generation = state(b).generation
    b[:conversation].update!(custom_attributes: { 'other' => true })
    PipelineClassification::Lifecycle.context_changed!(conversation: b[:conversation])
    expect(state(b).generation).to eq(generation)
    b[:conversation].update!(custom_attributes: { 'interested' => true })
    PipelineClassification::Lifecycle.context_changed!(conversation: b[:conversation])
    expect(state(b).generation).to eq(generation + 1)
  end

  it 'classifies conversations owned by a human' do
    b = business
    b[:conversation].update!(assignee: b[:user])
    incoming(b)
    row = due_result(b)
    client = evaluate(row)
    expect(client).to have_received(:call).once
    expect(row.reload.status).to eq('classified')
  end

  it 'debounces a new classification after a public outbound reply without a channel source id' do
    b = business
    incoming(b)
    initial_generation = state(b).generation
    b[:conversation].messages.create!(inbox: b[:inbox], message_type: :outgoing, status: :sent,
                                      content: 'Resposta enviada pelo atendente')
    expect(state(b).generation).to eq(initial_generation + 1)
    expect(state(b).due_at).to be_present
  end

  it 'expires accepted results at the original snapshot deadline even when result TTL is longer' do
    b = business
    profile = b[:pipeline].config['classification'].merge('snapshot_ttl_seconds' => 30, 'result_ttl_seconds' => 3600)
    b[:pipeline].update!(config: { 'classification' => profile })
    PipelineClassification::Editor.new(pipeline: b[:pipeline],
                                       actor: b[:user]).publish!(expected_hash: PipelineClassification::Catalog.new(b[:pipeline]).hash)
    incoming(b)
    row = due_result(b)
    evaluate(row)
    expect(row.reload.expires_at).to be <= row.created_at + 30.seconds
    expect(described_class.new(result: row, now: row.created_at + 31.seconds).current?).to be(false)
  end

  it 'does not reopen a generation for an older replayed event with the same timestamp' do
    b = business
    at = Time.current
    first = incoming(b, created_at: at)
    last = incoming(b, text: 'Actually I need support', created_at: at)
    generation = state(b).generation
    PipelineClassification::Lifecycle.incoming!(conversation: b[:conversation], message: first)
    expect(state(b).generation).to eq(generation)
    expect(state(b).source_incoming_message_id).to eq(last.id)
  end

  it 'uses the last twenty complete public messages without using the current card stage as evidence' do
    b = business
    22.times { |index| incoming(b, text: "Earlier question number #{index}", created_at: Time.current + index.seconds) }
    source = incoming(b, text: 'Não escolhi nenhuma opção e não confirmei a compra', created_at: 23.seconds.from_now)
    row = due_result(b)
    snapshot = PipelineClassification::SnapshotBuilder.new(result: row, catalog: row.pipeline_classification_catalog, conversation: b[:conversation],
                                                           now: source.created_at + 1.second).call
    expect(snapshot[:state]).to be_present
    expect(snapshot[:state]['history_truncated']).to be(true)
    expect(snapshot[:state]['messages'].size).to eq(20)
    expect(snapshot[:state]['messages'].last['content']).to eq('Não escolhi nenhuma opção e não confirmei a compra')
    expect(snapshot[:state]['messages'].last['created_at']).to be_present
    expect(snapshot[:state]).not_to have_key('current_stage')
    expect(snapshot[:references][:source_incoming_message_id]).to eq(source.id)
  end

  it 'abstains when a selected typed CRM field has no persisted value' do
    b = business
    CustomAttributeDefinition.create!(attribute_key: 'intent_known', attribute_display_name: 'Intent known',
                                      attribute_model: :conversation_attribute, attribute_display_type: :checkbox)
    profile = b[:pipeline].config['classification'].deep_dup
    profile['context_sources'] =
      { 'fields' => [{ 'key' => 'intent', 'source' => 'conversation.custom_attributes', 'field' => 'intent_known', 'type' => 'boolean' }] }
    b[:pipeline].update!(config: { 'classification' => profile })
    PipelineClassification::Editor.new(pipeline: b[:pipeline],
                                       actor: b[:user]).publish!(expected_hash: PipelineClassification::Catalog.new(b[:pipeline]).hash)
    incoming(b)
    row = due_result(b)
    client = evaluate(row)
    expect(client).not_to have_received(:call)
    expect(row.reload.reason).to eq('missing_selected_context')
  end

  it 'retires deleted conversation targets before scheduler enqueue and preserves unknown cost reservations' do
    b = business
    incoming(b)
    row = due_result(b)
    reservation = PipelineClassification::Budget.new(offline: true).reserve!(subject: row, catalog: row.pipeline_classification_catalog)
    reserved = reservation.pipeline_classification_budget_day.reload.reserved_usd
    row.update!(status: 'evaluating', fence_token: 1, attempt_count: 1, lease_expires_at: 30.seconds.from_now)
    # Native CRM removes cards before deleting a conversation. Simulate a bulk
    # or older writer lacking the new catalog hook, so FK retirement is tested
    # independently of the application-level invalidation callback.
    allow(PipelineClassification::ModelHooks).to receive(:pipeline_item_changed)
    b[:item].destroy!
    b[:conversation].destroy!
    allow(PipelineClassification::EvaluateJob).to receive(:perform_later)
    2.times { PipelineClassification::SchedulerJob.perform_now }
    expect(PipelineClassification::EvaluateJob).not_to have_received(:perform_later)
    expect(row.reload.status).to eq('cancelled')
    expect(row.reason).to eq('target_deleted')
    expect(row.fence_token).to eq(2)
    expect(reservation.reload.status).to eq('reserved')
    expect(reservation.pipeline_classification_budget_day.reload.reserved_usd).to eq(reserved)
  end

  it 'settles a known response after target deletion during HTTP and never re-enqueues the orphan' do
    b = business
    incoming(b)
    row = due_result(b)
    client = evaluate(row) do
      b[:item].destroy!
      b[:conversation].destroy!
    end
    expect(client).to have_received(:call).once
    expect(row.reload.status).to eq('cancelled')
    expect(row.reason).to match(/\A(?:target_deleted|pipeline_item_changed)\z/)
    expect(PipelineClassificationBudgetReservation.find_by!(pipeline_classification_result: row).status).to eq('settled')
    allow(PipelineClassification::EvaluateJob).to receive(:perform_later)
    2.times { PipelineClassification::SchedulerJob.perform_now }
    expect(PipelineClassification::EvaluateJob).not_to have_received(:perform_later)
  end

  it 'keeps accepted classification current across delivered/read receipts without a new generation' do
    b = business
    incoming(b)
    quote = b[:conversation].messages.create!(inbox: b[:inbox], message_type: :outgoing, status: :sent, source_id: 'synthetic-receipt',
                                              content: 'Here are the available options')
    row = due_result(b)
    client = evaluate(row)
    expect(row.reload.status).to eq('classified')
    generation = state(b).generation
    quote.update!(status: :delivered)
    quote.update!(status: :read)
    expect(state(b).generation).to eq(generation)
    expect(state(b).due_at).to be_nil
    expect(described_class.new(result: row).current?).to be(true)
    expect(client).to have_received(:call).once
  end

  it 'cancels a removed card state and does not schedule new results on subsequent incoming' do
    b = business
    incoming(b)
    row = due_result(b)
    evaluate(row)
    b[:item].destroy!
    expect(state(b).due_at).to be_nil
    incoming(b, text: 'A later message outside the old pipeline')
    expect(state(b).due_at).to be_nil
    expect(due_result(b)).to be_nil
    allow(PipelineClassification::EvaluateJob).to receive(:perform_later)
    expect { PipelineClassification::SchedulerJob.perform_now }.not_to change(PipelineClassificationResult, :count)
    expect(PipelineClassification::EvaluateJob).not_to have_received(:perform_later)
    expect(row.reload.status).to eq('cancelled')
  end

  it 'classifies once when an active card is created after its single source incoming' do
    b = business
    b[:item].destroy!
    source = incoming(b)
    expect(PipelineClassificationState.where(pipeline: b[:pipeline], conversation: b[:conversation])).to be_empty
    b[:item] = PipelineItem.create!(pipeline: b[:pipeline], pipeline_stage: b[:stage], conversation: b[:conversation])
    expect(state(b).source_incoming_message_id).to eq(source.id)
    travel 3.seconds
    client = instance_double(Ai::JevClient, call: response)
    allow(PipelineClassification::EvaluateJob).to receive(:perform_later) do |id|
      described_class.new(result: PipelineClassificationResult.find(id), client: client,
                          budget: PipelineClassification::Budget.new(offline: true)).call
    end
    2.times { PipelineClassification::SchedulerJob.perform_now }
    expect(client).to have_received(:call).once
    expect(PipelineClassification::EvaluateJob).to have_received(:perform_later).once
    expect(PipelineClassificationResult.where(pipeline: b[:pipeline], conversation: b[:conversation]).count).to eq(1)
    expect(PipelineClassificationResult.sole.source_incoming_message_id).to eq(source.id)
  ensure
    travel_back
  end

  it 'classifies independently of chatbot ignored-label and automation policies' do
    b = business
    label = Label.create!(title: "synthetic_block_#{SecureRandom.hex(4)}")
    bot = AgentBot.create!(name: 'Synthetic bot', bot_config: {})
    AgentBotInbox.create!(agent_bot: bot, inbox: b[:inbox], ignored_label_ids: [label.id], allowed_label_ids: [],
                          allowed_conversation_statuses: %w[pending open])
    b[:contact].add_labels([label.title])
    incoming(b)
    row = due_result(b)
    client = evaluate(row)
    expect(client).to have_received(:call).once
    expect(row.reload.status).to eq('classified')
    expect(row.decision['provider_latency_ms']).to be_a(Numeric)
  end

  it 'measures provider latency using its monotonic clock and ignores provider-supplied latency metadata' do
    b = business
    incoming(b)
    row = due_result(b)
    client = instance_double(Ai::JevClient, call: response.merge(provider_latency_ms: -999, raw_response: 'untrusted'))
    clock = instance_double(Proc)
    allow(clock).to receive(:call).and_return(10.0, 10.125)
    described_class.new(result: row, client: client, budget: PipelineClassification::Budget.new(offline: true),
                        monotonic_clock: lambda {
                          clock.call
                        }).call
    expect(row.reload.status).to eq('classified')
    expect(row.decision['provider_latency_ms']).to eq(125.0)
    expect(row.decision).not_to have_key('raw_response')
    expect(clock).to have_received(:call).twice
  end

  it 'records measured latency for a provider exception and preserves the unknown-charge reservation' do
    b = business
    incoming(b)
    row = due_result(b)
    client = double
    allow(client).to receive(:call).and_raise(IOError, 'synthetic provider failure')
    clock = instance_double(Proc)
    allow(clock).to receive(:call).and_return(20.0, 20.25)
    described_class.new(result: row, client: client, budget: PipelineClassification::Budget.new(offline: true),
                        monotonic_clock: lambda {
                          clock.call
                        }).call
    expect(row.reload.status).to eq('abstained')
    expect(row.decision['provider_latency_ms']).to eq(250.0)
    expect(PipelineClassificationBudgetReservation.find_by!(pipeline_classification_result: row).status).to eq('reserved')
  end

  # Keep the complete approval/race lifecycle and its observable side effects in one regression example.
  it 'abstains on overlapping stage criteria without using position as semantic priority' do # rubocop:disable RSpec/MultipleExpectations
    b = business
    shared = b[:stage].classification_profile.merge('entry_criteria' => ['The customer is considering the available options'])
    b[:stage].update!(classification_profile: shared)
    other = PipelineStage.create!(pipeline: b[:pipeline], name: 'Also considering', position: 2, classification_profile: shared)
    editor = PipelineClassification::Editor.new(pipeline: b[:pipeline].reload, actor: b[:user])
    editor.publish!(expected_hash: PipelineClassification::Catalog.new(b[:pipeline]).hash)
    compiled = PipelineClassification::Catalog.new(b[:pipeline]).compiled
    expect(compiled['aliases'].values).to contain_exactly(
      { 'pipeline_id' => b[:pipeline].id, 'stage_id' => b[:stage].id },
      { 'pipeline_id' => b[:pipeline].id, 'stage_id' => other.id }
    )
    expect(compiled.dig('questions', 'stage_candidate', 'criteria')).to have_key('unclear')
    other.update!(position: 9)
    expect(PipelineClassification::Catalog.new(b[:pipeline].reload).compiled).to eq(compiled)
    incoming(b)
    row = due_result(b)
    expect { evaluate(row, response(choice: 'unclear')) }.not_to change(Message, :count)
    expect(row.reload.status).to eq('abstained')
    expect(row.reason).to eq('uncertain_answer')
    expect(row.recommended_stage_id).to be_nil
    expect(b[:item].reload.pipeline_stage_id).to eq(b[:stage].id)
  end

  # Keep the complete approval/race lifecycle and its observable side effects in one regression example.
  it 'cancels a selected CRM field change during HTTP while preserving known actual usage' do # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
    b = business
    CustomAttributeDefinition.create!(attribute_key: 'interested', attribute_display_name: 'Interested', attribute_model: :conversation_attribute,
                                      attribute_display_type: :checkbox)
    profile = b[:pipeline].config['classification'].deep_dup
    profile['context_sources'] =
      { 'fields' => [{ 'key' => 'interest', 'source' => 'conversation.custom_attributes', 'field' => 'interested', 'type' => 'boolean' }] }
    b[:pipeline].update!(config: { 'classification' => profile })
    PipelineClassification::Editor.new(pipeline: b[:pipeline],
                                       actor: b[:user]).publish!(expected_hash: PipelineClassification::Catalog.new(b[:pipeline]).hash)
    b[:conversation].update!(custom_attributes: { 'interested' => false })
    incoming(b)
    row = due_result(b)
    initial_state = state(b)
    initial_digest = initial_state.context_digest
    initial_generation = initial_state.generation
    initial_snapshot = PipelineClassification::SnapshotBuilder.new(result: row, catalog: row.pipeline_classification_catalog,
                                                                   conversation: b[:conversation]).call
    client = evaluate(row) { b[:conversation].update!(custom_attributes: { 'interested' => true }) }
    expect(client).to have_received(:call).once
    expect(row.reload.status).to eq('cancelled')
    expect(state(b).generation).to eq(initial_generation + 1)
    expect(state(b).context_digest).not_to eq(initial_digest)
    reservation = PipelineClassificationBudgetReservation.find_by!(pipeline_classification_result: row)
    expect(reservation.status).to eq('settled')
    expect(reservation.actual_usd).to eq(BigDecimal('0.0000042'))
    replacement = due_result(b)
    fresh_snapshot = PipelineClassification::SnapshotBuilder.new(result: replacement, catalog: replacement.pipeline_classification_catalog,
                                                                 conversation: b[:conversation]).call
    expect(initial_snapshot.dig(:state, 'crm', 'interest')).to be(false)
    expect(fresh_snapshot.dig(:state, 'crm', 'interest')).to be(true)
    expect(fresh_snapshot[:snapshot_hash]).not_to eq(initial_snapshot[:snapshot_hash])
  end

  it 'compiles snapshot and provider questions from the immutable approved revision after a draft edit' do
    b = business
    incoming(b)
    row = due_result(b)
    approved = PipelineClassification::Catalog.from_revision(row.pipeline_classification_catalog).compiled
    # Edit after the initial snapshot was captured, simulating the narrow gap
    # before request construction; the injected provider exercises wire packing.
    allow(PipelineClassification::SnapshotBuilder).to receive(:new).and_wrap_original do |factory, **options|
      real_builder = factory.call(**options)
      wrapper = Object.new
      wrapper.define_singleton_method(:call) do
        snapshot = real_builder.call
        b[:stage].update!(classification_profile: b[:stage].classification_profile.merge('definition' => 'UNAPPROVED draft criteria'))
        snapshot
      end
      wrapper
    end
    client = instance_double(Ai::JevClient)
    allow(client).to receive(:call) do |**request|
      expect(request[:questions]).to eq(approved.fetch('questions'))
      expect(request[:questions].to_json).not_to include('UNAPPROVED')
      response
    end
    described_class.new(result: row, client: client, budget: PipelineClassification::Budget.new(offline: true)).call
    expect(client).to have_received(:call).once
    expect(row.reload.status).to eq('cancelled')
    expect(PipelineClassificationBudgetReservation.find_by!(pipeline_classification_result: row).status).to eq('settled')
    expect(PipelineClassification::Catalog.from_revision(row.pipeline_classification_catalog).compiled).to eq(approved)
  end

  it 'moves a fresh auto-mode recommendation once and records an automated stage movement' do
    b = business(mode: 'auto')
    next_stage = PipelineStage.create!(pipeline: b[:pipeline], name: 'Ready to book', position: 2,
                                       classification_profile: PipelineClassification::Catalog::DEFAULT_STAGE.deep_dup.merge(
                                         'classification_enabled' => true, 'definition' => 'Customer has decided to book'
                                       ))
    PipelineClassification::Editor.new(pipeline: b[:pipeline].reload,
                                       actor: b[:user]).publish!(expected_hash: PipelineClassification::Catalog.new(b[:pipeline]).hash)
    incoming(b, text: 'I am ready to book')
    row = due_result(b)
    aliases = PipelineClassification::Catalog.from_revision(row.pipeline_classification_catalog).compiled.fetch('aliases')
    target_alias = aliases.find { |_key, value| value['stage_id'] == next_stage.id }.first
    evaluate(row, response(choice: target_alias))

    first = PipelineClassification::ApplyDecision.new(result: row.reload).call
    second = PipelineClassification::ApplyDecision.new(result: row.reload).call

    expect(first['status']).to eq('applied'), first.inspect
    expect(second['status']).to eq('applied')
    expect(b[:item].reload.pipeline_stage_id).to eq(next_stage.id), first.inspect
    movement = b[:item].stage_movements.order(:created_at).last
    expect(movement.movement_type).to eq('automated')
    expect(movement.notes).to include("result=#{row.id}")
    expect(row.reload.decision.dig('application', 'status')).to eq('applied')
  end

  it 'moves across pipelines using the frozen target catalog and records a cross-pipeline audit' do # rubocop:disable RSpec/ExampleLength
    source = business(mode: 'auto')
    target_pipeline = Pipeline.create!(name: "Support #{SecureRandom.hex(5)}", created_by: source[:user])
    target_stage = PipelineStage.create!(pipeline: target_pipeline, name: 'Reservation support', position: 1,
                                         classification_profile: PipelineClassification::Catalog::DEFAULT_STAGE.deep_dup.merge(
                                           'classification_enabled' => true, 'definition' => 'Customer needs help with an existing reservation'
                                         ))
    target_profile = PipelineClassification::Catalog::DEFAULT_PROFILE.deep_dup.merge(
      'enabled' => true, 'mode' => 'observe', 'purpose' => 'Classify active reservation support', 'inbox_ids' => [source[:inbox].id]
    )
    target_pipeline.update!(config: { 'classification' => target_profile })
    PipelineClassification::Editor.new(pipeline: target_pipeline.reload,
                                       actor: source[:user]).publish!(expected_hash: PipelineClassification::Catalog.new(target_pipeline).hash)
    source_profile = source[:pipeline].config['classification'].merge('routing_pipeline_ids' => [source[:pipeline].id, target_pipeline.id])
    source[:pipeline].update!(config: { 'classification' => source_profile })
    PipelineClassification::Editor.new(pipeline: source[:pipeline].reload,
                                       actor: source[:user]).publish!(expected_hash: PipelineClassification::Catalog.new(source[:pipeline]).hash)

    incoming(source, text: 'I already booked and need help with the reservation')
    row = due_result(source)
    compiled = PipelineClassification::Catalog.from_revision(row.pipeline_classification_catalog).compiled
    pipeline_choice = compiled.fetch('pipeline_aliases').find { |_key, id| id == target_pipeline.id }.first
    stage_choice = compiled.fetch('aliases').find do |_key, value|
      value['pipeline_id'] == target_pipeline.id && value['stage_id'] == target_stage.id
    end.first
    evaluate(row, response(pipeline_choice: pipeline_choice, choice: stage_choice))

    application = PipelineClassification::ApplyDecision.new(result: row.reload).call
    expect(application['status']).to eq('applied')
    expect(source[:item].reload.pipeline_id).to eq(target_pipeline.id)
    expect(source[:item].pipeline_stage_id).to eq(target_stage.id)
    movement = source[:item].stage_movements.order(:created_at).last
    expect(movement.movement_type).to eq('cross_pipeline')
    expect(movement.notes).to include("result=#{row.id}")
  end

  it 'honors the installation level automatic movement pause' do
    b = business(mode: 'auto')
    installation = InstallationConfig.find_by!(name: 'PIPELINE_CLASSIFICATION_SETTINGS')
    installation.update!(value: installation.value.merge('automatic_moves_enabled' => false))
    incoming(b)
    row = due_result(b)
    evaluate(row)

    outcome = PipelineClassification::ApplyDecision.new(result: row.reload).call

    expect(outcome).to include('status' => 'skipped', 'reason' => 'automatic_moves_paused')
    expect(b[:item].reload.pipeline_stage_id).to eq(b[:stage].id)
  end

  it 'restarts classification when an outgoing message transitions from failed to delivered' do
    b = business
    incoming(b)
    outgoing = b[:conversation].messages.create!(inbox: b[:inbox], message_type: :outgoing, content: 'We will help', status: :failed)
    initial_generation = state(b).generation
    outgoing.update!(status: :sent)
    expect(state(b).generation).to eq(initial_generation + 1)
    expect(state(b).due_at).to be_present
  end

  it 'invalidates a pending snapshot when a public message is deleted' do
    b = business
    incoming(b)
    row = due_result(b)
    source = b[:conversation].messages.find(row.source_incoming_message_id)
    source.destroy!
    expect(row.reload.status).to eq('cancelled')
  end
end
