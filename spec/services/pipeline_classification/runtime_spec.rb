require 'rails_helper'

RSpec.describe 'Independent pipeline classification' do
  def business(name: 'Sales', debounce: 2000)
    user = User.create!(name: 'Synthetic operator', email: "pipeline-#{SecureRandom.hex(5)}@example.test")
    channel = Channel::WebWidget.create!(website_url: 'https://synthetic.example.test')
    inbox = Inbox.create!(name: name, channel: channel, enable_auto_assignment: false)
    contact = Contact.create!(name: 'Synthetic customer', email: "client-#{SecureRandom.hex(5)}@example.test")
    binding = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(5))
    conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: binding, status: :pending)
    pipeline = Pipeline.create!(name: "#{name} #{SecureRandom.hex(5)}", created_by: user)
    stage = PipelineStage.create!(pipeline: pipeline, name: 'Considering', position: 1)
    item = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation)
    profile = PipelineClassification::Catalog::DEFAULT_PROFILE.deep_dup.merge('purpose' => "Classify #{name} intent", 'enabled' => true, 'mode' => 'observe', 'inbox_ids' => [inbox.id], 'debounce_ms' => debounce)
    stage_profile = PipelineClassification::Catalog::DEFAULT_STAGE.deep_dup.merge('classification_enabled' => true, 'definition' => 'Customer is considering available options')
    pipeline.update!(config: { 'classification' => profile })
    stage.update!(classification_profile: stage_profile)
    catalog = PipelineClassification::Editor.new(pipeline: pipeline.reload, actor: user).publish!(expected_hash: PipelineClassification::Catalog.new(pipeline).hash)
    { user: user, inbox: inbox, contact: contact, conversation: conversation, pipeline: pipeline, stage: stage, item: item, catalog: catalog }
  end

  before do
    InstallationConfig.create!(name: 'PIPELINE_CLASSIFICATION_SETTINGS', value: { 'online_enabled' => true, 'privacy_reviewed' => true, 'language_validated' => true, 'billing_ceiling_verified' => true, 'retention_days' => 30, 'max_attempt_cost_usd' => 0.01 })
    InstallationConfig.create!(name: 'FOLLOWUP_SETTINGS', value: { 'budget_timezone' => 'UTC', 'daily_usd' => 1.0, 'daily_conversations' => 20 })
  end

  def incoming(b, text: 'Show me the available options', created_at: Time.current)
    message = b[:conversation].messages.create!(inbox: b[:inbox], message_type: :incoming, content: text, created_at: created_at)
    PipelineClassification::Lifecycle.incoming!(conversation: b[:conversation], message: message, now: created_at)
    message
  end

  def state(b)
    PipelineClassificationState.find_by!(pipeline: b[:pipeline], conversation: b[:conversation])
  end

  def due_result(b)
    row_state = state(b)
    return unless row_state.due_at
    PipelineClassification::DebouncedClassifier.new(state: row_state, generation: row_state.generation, now: row_state.due_at + 0.01).call
  end

  def response(choice: 'stage_1', confidence: 1.0, **overrides)
    { ok: true, model: PipelineClassification::Catalog::MODEL, answers: { 'stage_candidate' => { 'type' => 'choice', 'choice' => choice, 'confidence' => confidence } }, input_tokens: 100, usage_known: true, cost_known: true, cost_usd: 0.0000042 }.merge(overrides)
  end

  def evaluate(row, provider_response = response, &block)
    client = double('offline typed Jev')
    allow(client).to receive(:call) do |**_params|
      block&.call
      provider_response
    end
    budget = PipelineClassification::Budget.new(offline: true)
    PipelineClassification::Evaluator.new(result: row, client: client, budget: budget).call
    client
  end

  it 'classifies without any campaign, template, evidence or action and records real usage' do
    b = business
    incoming(b)
    row = due_result(b)
    expect { evaluate(row) }.not_to change(Message, :count)
    expect(row.reload.status).to eq('classified')
    expect(row.recommended_stage_id).to eq(b[:stage].id)
    expect(row.decision['financial_proof']).to be(false)
    expect(FollowupCampaign.count).to eq(0)
    expect(FollowupTemplate.count).to eq(0)
    expect(b[:item].reload.pipeline_stage_id).to eq(b[:stage].id)
    expect(FollowupBudgetReservation.where(subject: row).count).to eq(1)
  end

  it 'debounces each pipeline independently and accepts equal-timestamp events by serialized order' do
    b = business(debounce: 1000)
    other = business(name: 'Support', debounce: 5000)
    other[:item].update!(conversation: b[:conversation])
    profile = other[:pipeline].config['classification'].merge('inbox_ids' => [b[:inbox].id])
    other[:pipeline].update!(config: { 'classification' => profile })
    PipelineClassification::Editor.new(pipeline: other[:pipeline], actor: other[:user]).publish!(expected_hash: PipelineClassification::Catalog.new(other[:pipeline]).hash)
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
    expect(FollowupBudgetReservation.where(subject: row).count).to eq(1)
  end

  it 'preserves billed usage and invalidates a result when a new incoming arrives during HTTP' do
    b = business
    incoming(b)
    row = due_result(b)
    evaluate(row) { incoming(b, text: 'Can we discuss support instead?') }
    expect(row.reload.status).to eq('cancelled')
    expect(FollowupBudgetReservation.find_by!(subject: row).status).to eq('settled')
    expect(state(b).due_at).to be_present
  end

  it 'preserves billed usage and invalidates a result when the catalog changes during HTTP' do
    b = business
    incoming(b)
    row = due_result(b)
    evaluate(row) { b[:stage].update!(name: 'Renamed stage') }
    expect(row.reload.status).to eq('cancelled')
    expect(FollowupBudgetReservation.find_by!(subject: row).status).to eq('settled')
  end

  it 'abstains on unclear, insufficient confidence, unexpected model and unallowed alias' do
    [['unclear', 1.0, nil], ['stage_1', 0.2, nil], ['stage_1', 1.0, 'unexpected'], ['foreign_stage', 1.0, nil]].each_with_index do |(choice, confidence, model), index|
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

  it 'rejects alleged payment before HTTP and does not infer financial proof from CRM fields' do
    b = business
    incoming(b, text: 'Já paguei o pix e enviei o comprovante')
    row = due_result(b)
    client = evaluate(row)
    expect(client).not_to have_received(:call)
    expect(row.reload.status).to eq('abstained')
    expect(row.reason).to eq('payment_claim_requires_review')
  end

  it 'ignores unselected fields and invalidates selected enum/boolean changes' do
    b = business
    profile = b[:pipeline].config['classification'].deep_dup
    profile['context_sources'] = { 'fields' => [{ 'key' => 'interest', 'source' => 'conversation.custom_attributes', 'field' => 'interested', 'type' => 'boolean' }] }
    CustomAttributeDefinition.create!(attribute_key: 'interested', attribute_display_name: 'Interested', attribute_model: :conversation_attribute, attribute_display_type: :checkbox)
    b[:pipeline].update!(config: { 'classification' => profile })
    PipelineClassification::Editor.new(pipeline: b[:pipeline], actor: b[:user]).publish!(expected_hash: PipelineClassification::Catalog.new(b[:pipeline]).hash)
    incoming(b)
    generation = state(b).generation
    b[:conversation].update!(custom_attributes: { 'other' => true })
    PipelineClassification::Lifecycle.context_changed!(conversation: b[:conversation])
    expect(state(b).generation).to eq(generation)
    b[:conversation].update!(custom_attributes: { 'interested' => true })
    PipelineClassification::Lifecycle.context_changed!(conversation: b[:conversation])
    expect(state(b).generation).to eq(generation + 1)
  end

  it 'guards human ownership and blocked contacts before any provider request' do
    b = business
    incoming(b)
    row = due_result(b)
    b[:conversation].update!(assignee: b[:user])
    client = evaluate(row)
    expect(client).not_to have_received(:call)
    expect(row.reload.status).to satisfy { |status| %w[blocked cancelled].include?(status) }
  end
  it 'expires accepted results at the original snapshot deadline even when result TTL is longer' do
    b = business
    profile = b[:pipeline].config['classification'].merge('snapshot_ttl_seconds' => 30, 'result_ttl_seconds' => 3600)
    b[:pipeline].update!(config: { 'classification' => profile })
    PipelineClassification::Editor.new(pipeline: b[:pipeline], actor: b[:user]).publish!(expected_hash: PipelineClassification::Catalog.new(b[:pipeline]).hash)
    incoming(b)
    row = due_result(b)
    evaluate(row)
    expect(row.reload.expires_at).to be <= row.created_at + 30.seconds
    expect(PipelineClassification::Evaluator.new(result: row, now: row.created_at + 31.seconds).current?).to be(false)
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

  it 'uses the last eight complete public messages and preserves the latest negation after long history' do
    b = business
    10.times { |index| incoming(b, text: "Earlier question number #{index}", created_at: Time.current + index.seconds) }
    source = incoming(b, text: 'Não escolhi nenhuma opção e não confirmei a compra', created_at: Time.current + 11.seconds)
    row = due_result(b)
    snapshot = PipelineClassification::SnapshotBuilder.new(result: row, catalog: row.pipeline_classification_catalog, conversation: b[:conversation], now: source.created_at + 1.second).call
    expect(snapshot[:state]).to be_present
    expect(snapshot[:state]['history_truncated']).to be(true)
    expect(snapshot[:state]['messages'].size).to eq(8)
    expect(snapshot[:state]['messages'].last['content']).to eq('Não escolhi nenhuma opção e não confirmei a compra')
    expect(snapshot[:references][:source_incoming_message_id]).to eq(source.id)
  end

  it 'abstains when a selected typed CRM field has no persisted value' do
    b = business
    CustomAttributeDefinition.create!(attribute_key: 'intent_known', attribute_display_name: 'Intent known', attribute_model: :conversation_attribute, attribute_display_type: :checkbox)
    profile = b[:pipeline].config['classification'].deep_dup
    profile['context_sources'] = { 'fields' => [{ 'key' => 'intent', 'source' => 'conversation.custom_attributes', 'field' => 'intent_known', 'type' => 'boolean' }] }
    b[:pipeline].update!(config: { 'classification' => profile })
    PipelineClassification::Editor.new(pipeline: b[:pipeline], actor: b[:user]).publish!(expected_hash: PipelineClassification::Catalog.new(b[:pipeline]).hash)
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
    reserved = reservation.followup_budget_day.reload.reserved_usd
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
    expect(reservation.followup_budget_day.reload.reserved_usd).to eq(reserved)
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
    expect(%w[target_deleted pipeline_item_changed]).to include(row.reason)
    expect(FollowupBudgetReservation.find_by!(subject: row).status).to eq('settled')
    allow(PipelineClassification::EvaluateJob).to receive(:perform_later)
    2.times { PipelineClassification::SchedulerJob.perform_now }
    expect(PipelineClassification::EvaluateJob).not_to have_received(:perform_later)
  end

  it 'keeps accepted classification current across delivered/read receipts without a new generation' do
    b = business
    incoming(b)
    quote = b[:conversation].messages.create!(inbox: b[:inbox], message_type: :outgoing, status: :sent, source_id: 'synthetic-receipt', content: 'Here are the available options')
    row = due_result(b)
    client = evaluate(row)
    expect(row.reload.status).to eq('classified')
    generation = state(b).generation
    quote.update!(status: :delivered)
    quote.update!(status: :read)
    expect(state(b).generation).to eq(generation)
    expect(state(b).due_at).to be_nil
    expect(PipelineClassification::Evaluator.new(result: row).current?).to be(true)
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
    client = double('one standalone provider', call: response)
    allow(PipelineClassification::EvaluateJob).to receive(:perform_later) do |id|
      PipelineClassification::Evaluator.new(result: PipelineClassificationResult.find(id), client: client, budget: PipelineClassification::Budget.new(offline: true)).call
    end
    2.times { PipelineClassification::SchedulerJob.perform_now }
    expect(client).to have_received(:call).once
    expect(PipelineClassification::EvaluateJob).to have_received(:perform_later).once
    expect(PipelineClassificationResult.where(pipeline: b[:pipeline], conversation: b[:conversation]).count).to eq(1)
    expect(PipelineClassificationResult.sole.source_incoming_message_id).to eq(source.id)
  ensure
    travel_back
  end

  it 'applies the inbox ignored-label binding before any standalone provider request or budget reservation' do
    b = business
    label = Label.create!(title: "synthetic_block_#{SecureRandom.hex(4)}")
    bot = AgentBot.create!(name: 'Synthetic bot', bot_config: {})
    AgentBotInbox.create!(agent_bot: bot, inbox: b[:inbox], ignored_label_ids: [label.id], allowed_label_ids: [], allowed_conversation_statuses: %w[pending open])
    b[:contact].add_labels([label.title])
    incoming(b)
    row = due_result(b)
    client = evaluate(row)
    expect(client).not_to have_received(:call)
    expect(row.reload.status).to eq('blocked')
    expect(row.reason).to eq('inbox_bot_policy_block')
    expect(FollowupBudgetReservation.where(subject: row)).to be_empty
    expect(row.decision).not_to have_key('provider_latency_ms')
  end

  it 'measures provider latency using its monotonic clock and ignores provider-supplied latency metadata' do
    b = business
    incoming(b)
    row = due_result(b)
    client = double(call: response.merge(provider_latency_ms: -999, raw_response: 'untrusted'))
    clock = double('monotonic clock')
    allow(clock).to receive(:call).and_return(10.0, 10.125)
    PipelineClassification::Evaluator.new(result: row, client: client, budget: PipelineClassification::Budget.new(offline: true), monotonic_clock: -> { clock.call }).call
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
    clock = double('monotonic clock')
    allow(clock).to receive(:call).and_return(20.0, 20.25)
    PipelineClassification::Evaluator.new(result: row, client: client, budget: PipelineClassification::Budget.new(offline: true), monotonic_clock: -> { clock.call }).call
    expect(row.reload.status).to eq('abstained')
    expect(row.decision['provider_latency_ms']).to eq(250.0)
    expect(FollowupBudgetReservation.find_by!(subject: row).status).to eq('reserved')
  end

  it 'abstains on overlapping stage criteria without using position as semantic priority' do
    b = business
    shared = b[:stage].classification_profile.merge('entry_criteria' => ['The customer is considering the available options'])
    b[:stage].update!(classification_profile: shared)
    other = PipelineStage.create!(pipeline: b[:pipeline], name: 'Also considering', position: 2, classification_profile: shared)
    editor = PipelineClassification::Editor.new(pipeline: b[:pipeline].reload, actor: b[:user])
    editor.publish!(expected_hash: PipelineClassification::Catalog.new(b[:pipeline]).hash)
    compiled = PipelineClassification::Catalog.new(b[:pipeline]).compiled
    expect(compiled['aliases'].values).to contain_exactly(b[:stage].id, other.id)
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

  it 'cancels a selected CRM field change during HTTP while preserving known actual usage' do
    b = business
    CustomAttributeDefinition.create!(attribute_key: 'interested', attribute_display_name: 'Interested', attribute_model: :conversation_attribute, attribute_display_type: :checkbox)
    profile = b[:pipeline].config['classification'].deep_dup
    profile['context_sources'] = { 'fields' => [{ 'key' => 'interest', 'source' => 'conversation.custom_attributes', 'field' => 'interested', 'type' => 'boolean' }] }
    b[:pipeline].update!(config: { 'classification' => profile })
    PipelineClassification::Editor.new(pipeline: b[:pipeline], actor: b[:user]).publish!(expected_hash: PipelineClassification::Catalog.new(b[:pipeline]).hash)
    b[:conversation].update!(custom_attributes: { 'interested' => false })
    incoming(b)
    row = due_result(b)
    initial_state = state(b)
    initial_digest, initial_generation = initial_state.context_digest, initial_state.generation
    initial_snapshot = PipelineClassification::SnapshotBuilder.new(result: row, catalog: row.pipeline_classification_catalog, conversation: b[:conversation]).call
    client = evaluate(row) { b[:conversation].update!(custom_attributes: { 'interested' => true }) }
    expect(client).to have_received(:call).once
    expect(row.reload.status).to eq('cancelled')
    expect(state(b).generation).to eq(initial_generation + 1)
    expect(state(b).context_digest).not_to eq(initial_digest)
    reservation = FollowupBudgetReservation.find_by!(subject: row)
    expect(reservation.status).to eq('settled')
    expect(reservation.actual_usd).to eq(BigDecimal('0.0000042'))
    replacement = due_result(b)
    fresh_snapshot = PipelineClassification::SnapshotBuilder.new(result: replacement, catalog: replacement.pipeline_classification_catalog, conversation: b[:conversation]).call
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
    client = double('approved revision provider')
    allow(client).to receive(:call) do |**request|
      expect(request[:questions]).to eq(approved.fetch('questions'))
      expect(request[:questions].to_json).not_to include('UNAPPROVED')
      response
    end
    PipelineClassification::Evaluator.new(result: row, client: client, budget: PipelineClassification::Budget.new(offline: true)).call
    expect(client).to have_received(:call).once
    expect(row.reload.status).to eq('cancelled')
    expect(FollowupBudgetReservation.find_by!(subject: row).status).to eq('settled')
    expect(PipelineClassification::Catalog.from_revision(row.pipeline_classification_catalog).compiled).to eq(approved)
  end

end
