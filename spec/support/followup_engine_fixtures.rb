require 'digest'

module FollowupEngineFixtures
  # Keep the complete multi-record integration scenario and its atomic safety assertions together.
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
  def build_followup_business(name: 'Travel desk', timezone: 'America/Sao_Paulo', stage_name: 'Options shared', label_name: 'contact_stop',
                              cohort_percentage: 100, mode: 'active', live_ready: false, policy_label_guard: true)
    user = User.create!(name: 'Synthetic operator', email: "followup-#{SecureRandom.hex(6)}@example.test")
    channel = Channel::WebWidget.create!(website_url: 'https://synthetic.example.test')
    inbox = Inbox.create!(name: name, channel: channel, enable_auto_assignment: false)
    contact = Contact.create!(name: 'Synthetic customer', email: "fixture-#{SecureRandom.hex(6)}@example.test")
    contact_inbox = ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8))
    conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :pending)
    pipeline = Pipeline.create!(name: name, pipeline_type: 'custom', created_by: user)
    stage = PipelineStage.create!(pipeline: pipeline, name: stage_name, position: 1)
    item = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation)
    label = Label.create!(title: "#{label_name}_#{SecureRandom.hex(4)}")
    body = "Can I answer a question about the #{name.downcase} options?"
    template = FollowupTemplate.create!(template_key: "#{name.parameterize}_#{SecureRandom.hex(4)}", version: 'v1', body: body,
                                        body_digest: Digest::SHA256.hexdigest(body), approved_by: user, approved_at: Time.current, active: true)
    policy = {
      'timezone' => timezone, 'debounce_ms' => 1500, 'reclassification_enabled' => true,
      'contact_window' => { 'start' => '00:00', 'end' => '23:59', 'weekdays' => (0..6).to_a },
      'steps' => [{ 'step_id' => 'first', 'delay_minutes' => 10, 'template_id' => template.id }],
      'max_lateness_minutes' => 60, 'authorization_ttl_seconds' => 600, 'cooldown_minutes' => 60,
      'allowed_statuses' => %w[open pending], 'blocking_label_ids' => [],
      'opt_out_label_ids' => policy_label_guard ? [label.id] : [], 'consent_label_ids' => [],
      'label_bindings' => policy_label_guard ? { label.id => label.title } : {},
      'channel_authorization' => { 'provider' => channel.class.name, 'approved' => true, 'window_seconds' => 86_400, 'template_required' => false },
      'cohort' => { 'salt' => 'synthetic-installation', 'percentage' => cohort_percentage },
      'classifier' => {
        'model' => 'jev-1.14.0', 'question_version' => 'synthetic-v1',
        'questions' => { 'next_owner' => { 'type' => 'choice', 'instructions' => 'Who is expected to act?',
                                           'criteria' => { 'customer' => 'Customer is deciding', 'company' => 'Company owes an answer',
                                                           'unclear' => 'Insufficient evidence' }, 'min_confidence' => 0.95 } },
        'conditions' => [{ 'action' => 'send', 'reason' => 'customer_deciding', 'template_id' => template.id,
                           'when' => { 'all' => [{ 'question' => 'next_owner', 'field' => 'choice', 'op' => 'eq', 'value' => 'customer' }] } }]
      },
      'limits' => { 'daily_conversations' => 20, 'daily_usd' => 1.0, 'max_attempts' => 2,
                    'max_billable_tokens_per_attempt' => 64_000, 'billing_ceiling_verified' => live_ready },
      'approvals' => { 'templates_reviewed' => true, 'privacy_reviewed' => live_ready, 'retention_days' => 30, 'language_validated' => live_ready }
    }
    campaign = FollowupCampaign.create!(campaign_key: SecureRandom.uuid, pipeline_stage: stage, inbox: inbox, policy_version: 'v1', enabled: true,
                                        mode: mode, active_from: 1.hour.ago, policy: policy)
    incoming = conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'Please show the options', created_at: 20.minutes.ago)
    anchor = conversation.messages.create!(inbox: inbox, message_type: :outgoing, content: "Here are the #{name.downcase} options",
                                           status: :delivered, source_id: SecureRandom.hex(8), created_at: 19.minutes.ago)
    evidence = Followups::EvidenceApproval.new(campaign: campaign, conversation: conversation, pipeline_item: item, incoming: incoming,
                                               anchor: anchor, actor: user).call
    { user: user, inbox: inbox, contact: contact, conversation: conversation, pipeline: pipeline, stage: stage, item: item, label: label,
      template: template, campaign: campaign, incoming: incoming, anchor: anchor, evidence: evidence, execution: campaign.followup_executions.first }
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists

  def fake_followup_snapshot
    { state: 'Synthetic minimized context', snapshot_hash: 'synthetic-hash', references: {}, valid_until: 5.minutes.from_now }
  end

  def fake_followup_result(business, **overrides)
    { action: 'send', reason: 'customer_deciding', template_id: business[:template].id, model: 'jev-1.14.0', question_version: 'synthetic-v1',
      input_tokens: 123, usage_known: true, retryable: false, retry_after: nil }.merge(overrides)
  end

  def offline_followup_budget(**settings)
    Followups::Budget.new(offline: true,
                          settings: { 'budget_timezone' => 'UTC', 'daily_usd' => 1.0,
                                      'daily_conversations' => 20 }.merge(settings.stringify_keys))
  end

  def evaluate_followup(business, result: nil, classifier: nil, subject: nil)
    classifier ||= instance_double(Followups::Classifier, classify: result || fake_followup_result(business))
    Followups::Evaluator.new(subject: subject || business[:execution], classifier: classifier,
                             snapshot_builder: instance_double(Followups::SnapshotBuilder, call: fake_followup_snapshot),
                             budget: offline_followup_budget).call
  end
end
