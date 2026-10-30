# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Followups::SnapshotBuilder do
  let(:now) { Time.current.change(usec: 0) }
  let(:contact) { Contact.create!(name: 'Marina Oliveira', last_name: 'Oliveira', email: 'marina@example.test', phone_number: '+5511998765432') }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://synthetic.example.test') }
  let(:inbox) { Inbox.create!(name: 'Synthetic scheduling', channel: channel) }
  let(:conversation) do
    link = ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8))
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: link)
  end
  let(:questions) do
    { 'owner' => { 'type' => 'choice', 'instructions' => 'Who must act?', 'criteria' => { 'customer' => 'Customer chooses', 'unclear' => 'Unknown' },
                   'min_confidence' => 0.8 } }
  end
  let(:campaign) do
    instance_double(FollowupCampaign, id: 'synthetic-campaign', pipeline_catalog?: false, pipeline_stage_id: SecureRandom.uuid, inbox_id: inbox.id,
                                      active_from: now - 3600, expires_at: now + 600, policy_version: 'v1',
                                      policy: { 'classifier' => { 'questions' => questions } })
  end
  let!(:incoming) { create_message(content: 'Vou pensar e retorno depois', message_type: :incoming, created_at: now - 120) }
  let!(:anchor) { create_message(content: 'Aqui estão as opções solicitadas', message_type: :outgoing, status: :delivered, created_at: now - 60) }
  let(:evidence) do
    instance_double(FollowupAnchorEvidence, anchor_message_id: anchor.id, conversation_id: conversation.id, followup_campaign_id: campaign.id,
                                            source_incoming_message_id: incoming.id, verified_by_id: 'human-reviewer', verified_at: now - 30,
                                            pipeline_item_id: 'synthetic-pipeline-item',
                                            anchor_digest: Followups::EvidenceApproval.digest(anchor))
  end
  let(:execution) do
    instance_double(FollowupExecution, conversation: conversation, conversation_id: conversation.id, source_incoming_message_id: incoming.id,
                                       quote_anchor_message_id: anchor.id, followup_anchor_evidence: evidence, expires_at: now + 180,
                                       pipeline_item_id: 'synthetic-pipeline-item',
                                       authorized_revision: 4)
  end
  let(:classification) do
    instance_double(FollowupClassification, conversation: conversation, conversation_id: conversation.id, source_incoming_message_id: incoming.id,
                                            generation: 3, revision: 4, expires_at: now + 180)
  end

  before do
    # Inserting messages directly avoids ordinary CRM callbacks and any queued
    # provider effects. Every query below still uses actual PostgreSQL rows.
    allow(FollowupConversationState).to receive(:find_by).and_return(instance_double(FollowupConversationState,
                                                                                     classification_generation: 3, latest_incoming_message_id: nil))
  end

  def create_message(**attributes)
    id = SecureRandom.uuid
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    Message.insert_all!([{ id: id, conversation_id: conversation.id, inbox_id: inbox.id, private: false,
                           # rubocop:enable Rails/SkipsModelValidations
                           message_type: Message.message_types[:incoming], status: Message.statuses[:sent],
                           content_type: Message.content_types[:text], content: 'Synthetic text',
                           content_attributes: {}, additional_attributes: {}, created_at: now - 20, updated_at: now,
                           **attributes }])
    Message.find(id)
  end

  def build
    described_class.new(execution: execution, campaign: campaign, now: now).call
  end

  it 'includes both mandatory source before the anchor and the delivered approved anchor' do
    snapshot = build
    expect(snapshot[:state]['messages'].map { |message| message['content'] }).to eq([incoming.content, anchor.content])
    expect(snapshot[:references]).to include(source_incoming_message_id: incoming.id, anchor_message_id: anchor.id, generation: 3, revision: 4)
    expect(snapshot[:state].to_json).not_to include(conversation.id, contact.id, contact.name, contact.email)
    expect(snapshot[:snapshot_hash]).to match(/\A[0-9a-f]{64}\z/)
  end

  it 'keeps the hash stable when only cutoff time changes' do
    first = build
    second = described_class.new(execution: execution, campaign: campaign, now: now + 1).call
    expect(second[:snapshot_hash]).to eq(first[:snapshot_hash])
    expect(second[:references][:cutoff]).not_to eq(first[:references][:cutoff])
  end

  it 'supports classification without an approved outbound anchor' do
    snapshot = described_class.new(classification: classification, campaign: campaign, now: now).call
    expect(snapshot[:state]).to be_a(Hash)
    expect(snapshot[:references]).to include(anchor_message_id: nil, generation: 3, revision: 4)
  end

  it 'selects typed campaign-specific CRM facts and includes their changes in the snapshot hash' do
    campaign.policy['snapshot_context'] = { 'stage_key' => 'appointment_offer', 'fields' => [
      { 'key' => 'appointment_type', 'source' => 'conversation.custom_attributes', 'field' => 'appointment_type', 'type' => 'enum',
        'allowed_values' => %w[first_visit followup] },
      { 'key' => 'needs_callback', 'source' => 'contact.custom_attributes', 'field' => 'needs_callback', 'type' => 'boolean' }
    ] }
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    conversation.update_columns(custom_attributes: { 'appointment_type' => 'first_visit', 'private_name' => 'Never export this' })
    # rubocop:enable Rails/SkipsModelValidations
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    contact.update_columns(custom_attributes: { 'needs_callback' => false, 'private_email' => 'do-not-export@example.test' })
    # rubocop:enable Rails/SkipsModelValidations
    first = build
    expect(first[:state]['crm']).to eq('stage' => 'appointment_offer', 'appointment_type' => 'first_visit', 'needs_callback' => false)
    expect(first[:state].to_json).not_to include('Never export', 'do-not-export', conversation.id, contact.id)
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    conversation.update_columns(custom_attributes: { 'appointment_type' => 'followup' })
    # rubocop:enable Rails/SkipsModelValidations
    expect(build[:snapshot_hash]).not_to eq(first[:snapshot_hash])
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    conversation.update_columns(custom_attributes: { 'appointment_type' => 'unapproved_value' })
    # rubocop:enable Rails/SkipsModelValidations
    expect(build).to include(state: nil, reason: 'invalid_crm_context_value')
  end

  it 'validates CRM context configuration through Policy before external calls' do
    errors = Followups::Policy.new('snapshot_context' => { 'fields' => [{ 'source' => 'contact.email' }] }).errors
    expect(errors).to include('snapshot_context must select bounded typed CRM facts from allowed sources')
  end

  it 'includes the entire public post-anchor sequence or abstains when it does not fit' do
    8.times { |index| create_message(content: "mensagem #{index}", created_at: now - 40 + index) }
    # A newer incoming also invalidates the original cycle immediately.
    allow(classification).to receive(:source_incoming_message_id).and_return(Message.where(message_type: :incoming)
      .reorder(created_at: :desc).first.id)
    expect(described_class.new(classification: classification, campaign: campaign,
                               now: now).call).to include(state: nil, reason: 'snapshot_too_many_messages')
  end

  it 'abstains on an item exceeding 800 characters instead of truncating its negation' do
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    incoming.update_columns(content: "#{'a' * 800} não")
    # rubocop:enable Rails/SkipsModelValidations
    expect(build).to include(state: nil, reason: 'snapshot_message_too_long')
  end

  it 'counts question bytes in the request cap' do
    questions['owner']['instructions'] = Array.new(4, 'é' * 1500)
    expect(build).to include(state: nil, reason: 'snapshot_too_large')
  end

  it 'never includes private, failed, cancelled or revoked text' do
    create_message(content: 'PRIVATE_SECRET', message_type: :outgoing, private: true)
    create_message(content: 'FAILED_SECRET', message_type: :outgoing, status: :failed)
    create_message(content: 'CANCELLED_SECRET', message_type: :outgoing, additional_attributes: { 'cancelled' => true })
    create_message(content: 'REVOKED_SECRET', message_type: :outgoing, content_attributes: { 'revoked_by_contact' => true })
    text = build[:state].to_json
    expect(text).not_to match(/PRIVATE_SECRET|FAILED_SECRET|CANCELLED_SECRET|REVOKED_SECRET/)
  end

  it 'redacts known identities, arbitrary email, formatted phone, tax IDs and links' do
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    incoming.update_columns(content: 'Marina Oliveira, marina@example.test; other.person@example.test, ' \
                                     '+55 (11) 99876-5432 CPF 123.456.789-01 veja https://example.test/path?token=opaque')
    # rubocop:enable Rails/SkipsModelValidations
    state = build[:state]
    expect(state).to be_a(Hash)
    json = state.to_json
    expect(json).not_to match(/Marina|Oliveira|@example|99876|123.456|opaque|https:/)
  end

  it 'abstains on actual payment claims and credentials before external requests' do
    ['pix pago na conta 1234', 'Já paguei a reserva', 'enviei o comprovante', 'payment completed', 'bearer secret-value'].each do |text|
      # Inject persisted stale test state without callbacks so the safety rejection is exercised.
      # rubocop:disable Rails/SkipsModelValidations
      incoming.update_columns(content: text)
      # rubocop:enable Rails/SkipsModelValidations
      expect(build[:state]).to be_nil
    end
  end

  it 'redacts commercial values and specific references without removing negative booking conditions' do
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    incoming.update_columns(content: 'Orçamento de R$ 1.250,00; reserva ABC1234 e booking confirmation ' \
                                     'XYZ. A reserva ainda não está confirmada e não quero pagar agora.')
    # rubocop:enable Rails/SkipsModelValidations
    snapshot = build
    expect(snapshot[:state]).to be_a(Hash)
    text = snapshot[:state]['messages'].first['content']
    expect(text).to include('[amount]', '[reference]', 'A reserva ainda não está confirmada', 'não quero pagar agora')
    expect(text).not_to match(/1\.250|ABC1234|XYZ/)
  end

  it 'preserves negative and conditional words even in capitalized product or reference positions' do
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    incoming.update_columns(content: 'Opção 1: Sem Vagas; booking NOT CONFIRMED; reserva NÃO CONFIRMADA. Apenas Se houver disponibilidade.')
    # rubocop:enable Rails/SkipsModelValidations
    snapshot = build
    expect(snapshot[:state]).to be_a(Hash)
    expect(snapshot[:state]['messages'].first['content']).to include('Sem Vagas', 'NOT CONFIRMED', 'NÃO CONFIRMADA', 'Apenas Se')
  end

  # Keep the complete multi-record integration scenario and its atomic safety assertions together.
  # rubocop:disable RSpec/ExampleLength
  it 'classifies a complete realistic three-option quote after configurable minimization' do
    description = 'A proposta contempla o período solicitado e está sujeita à confirmação; não ' \
                  'inclui despesas extras. O cliente pode comparar as alternativas antes de decidir. '
    quote = "Marina, seguem três opções de orçamento para sua escolha:\n" \
            "Opção 1: Parque Sereno — total R$ 1.250,00. #{description} https://example.test/product/one?token=first-secret\n" \
            "Opção 2: Jardim Claro — total R$ 1.450,00. #{description} https://example.test/product/two?token=second-secret\n" \
            "Opção 3: Vale Aberto — total R$ 1.650,00. #{description} https://example.test/customer/booking/third-secret\n" \
            'A reserva ainda não está confirmada; não há garantia de disponibilidade até a verificação final. Posso ajudar com alguma dúvida?'
    expect(quote.length).to be > 800
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    anchor.update_columns(content: quote)
    # rubocop:enable Rails/SkipsModelValidations
    campaign.policy['snapshot_limits'] = { 'max_message_characters' => 2000 }
    reviewer = User.create!(name: 'Synthetic reviewer', email: "quote-reviewer-#{SecureRandom.hex(4)}@example.test")
    body = 'Posso ajudar com alguma dúvida para sua escolha?'
    template = FollowupTemplate.create!(template_key: "quote-test-#{SecureRandom.hex(4)}", version: '1', body: body,
                                        approved_by: reviewer, approved_at: now, active: true, body_digest: Digest::SHA256.hexdigest(body))
    campaign.policy['classifier'].merge!('model' => 'jev-1.14.0', 'question_version' => 'quote-observation-v1',
                                         'conditions' => [{ 'action' => 'send', 'reason' => 'customer_choosing', 'template_id' => template.id,
                                                            'when' => { 'question' => 'owner', 'field' => 'choice',
                                                                        'op' => 'eq', 'value' => 'customer' } }])
    snapshot = build
    expect(snapshot[:state]).to be_a(Hash)
    minimized = snapshot[:state]['messages'].last['content']
    expect(minimized).to include('não inclui despesas extras', 'A reserva ainda não está confirmada', 'não há garantia de disponibilidade')
    expect(minimized).not_to match(/1\.250|1\.450|1\.650|Parque Sereno|Jardim Claro|Vale Aberto|Marina|https:|secret/)
    calls = 0
    transport = lambda do |**request|
      calls += 1
      expect(request[:body].bytesize).to be <= 12 * 1024
      { status: 200, body: JSON.generate(model: 'jev-1.14.0', answers: { owner: { type: 'choice', choice: 'customer', confidence: 0.98,
                                                                                  probabilities: { customer: 0.99, unclear: 0.01 } } },
                                         usage: { input_tokens: 450, output_tokens: 12 }) }
    end
    result = Followups::Classifier.new(client: Ai::JevClient.new(transport: transport)).classify(snapshot: snapshot, policy: campaign.policy)
    expect(result).to include(action: 'send', template_id: template.id, usage_known: true)
    expect(calls).to eq(1)
  end
  # rubocop:enable RSpec/ExampleLength

  it 'allows configured message counts while preserving the entire sequence' do
    9.times { |index| create_message(content: "mensagem #{index}", created_at: now - 40 + index) }
    allow(classification).to receive(:source_incoming_message_id).and_return(Message.where(message_type: :incoming)
      .reorder(created_at: :desc).first.id)
    campaign.policy['snapshot_limits'] = { 'max_messages' => 10 }
    snapshot = described_class.new(classification: classification, campaign: campaign, now: now).call
    expect(snapshot[:state]['messages'].length).to eq(10)
    campaign.policy['snapshot_limits']['max_messages'] = 9
    expect(described_class.new(classification: classification, campaign: campaign,
                               now: now).call).to include(state: nil, reason: 'snapshot_too_many_messages')
  end

  it 'enforces hard safety ceilings and configured request bytes without truncation' do
    [{ 'max_messages' => 17 }, { 'max_message_characters' => 4001 }, { 'max_request_bytes' => 12_289 }, { 'max_messages' => '10' },
     { 'unknown' => 1 }].each do |limits|
      campaign.policy['snapshot_limits'] = limits
      expect(build).to include(state: nil, reason: 'invalid_snapshot_limits')
    end
    campaign.policy['snapshot_limits'] = { 'max_request_bytes' => 100 }
    expect(build).to include(state: nil, reason: 'snapshot_too_large')
  end

  it 'abstains when identity cannot be confidently minimized' do
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    incoming.update_columns(content: 'meu nome é Carlos Almeida')
    # rubocop:enable Rails/SkipsModelValidations
    expect(build).to include(state: nil, reason: 'unresolved_identity')
  end

  it 'abstains for unknown multimodal content even if a caption is present' do
    evidence
    # Rails constructs these request boundaries internally; isolate authentication/association reads at that boundary.
    # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(Message).to receive(:attachments).and_return(instance_double(ActiveRecord::Relation, exists?: true))
    # rubocop:enable RSpec/AnyInstance
    expect(build).to include(state: nil, reason: 'unknown_multimodal_content')
  end

  it 'rejects changed anchor content, default sent status and another conversation' do
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    anchor.update_columns(status: :sent)
    # rubocop:enable Rails/SkipsModelValidations
    expect(build[:state]).to be_nil
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    anchor.update_columns(status: :delivered, content: 'Changed body')
    # rubocop:enable Rails/SkipsModelValidations
    expect(build).to include(state: nil, reason: 'anchor_changed')
    allow(evidence).to receive(:conversation_id).and_return(SecureRandom.uuid)
    expect(build).to include(state: nil, reason: 'anchor_identity_mismatch')
  end

  it 'does not send after a newer outgoing or incoming' do
    create_message(content: 'Additional response', message_type: :outgoing)
    expect(build).to include(state: nil, reason: 'anchor_not_current')
    create_message(content: 'New incoming', message_type: :incoming)
    expect(build).to include(state: nil, reason: 'stale_source_incoming')
  end
end
