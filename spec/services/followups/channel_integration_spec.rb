require 'rails_helper'
require 'database_cleaner/active_record'
require 'timeout'
require_relative '../../support/followup_engine_fixtures'

# This integration scenario spans the scheduler, classifier, evidence and dispatch contracts.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Modular follow-up channel boundary' do
  # rubocop:enable RSpec/DescribeClass
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
    stub_const('SyntheticFollowupChannel', Class.new(Base::SendOnChannelService) do
      class << self
        attr_accessor :provider
      end

      private

      def channel_class
        Channel::WebWidget
      end

      def perform_reply
        provider_id = self.class.provider.call(message)
        message.update!(source_id: provider_id) if provider_id
      end
    end)
  end

  def queued_business
    business = build_followup_business
    evaluate_followup(business)
    expect(business[:execution].reload.status).to eq('queued')
    business
  end

  def deliver(message)
    SyntheticFollowupChannel.new(message: message).perform
  end

  it 'calls the fake provider only once for two simultaneous workers of the SAME Message' do
    business = queued_business
    id = business[:execution].message_id
    entered = Queue.new
    release = Queue.new
    calls = Queue.new
    SyntheticFollowupChannel.provider = lambda do |_message|
      calls << :called
      entered << true
      release.pop
      'synthetic-provider-once'
    end
    first = Thread.new { ActiveRecord::Base.connection_pool.with_connection { deliver(Message.find(id)) } }
    Timeout.timeout(5) { entered.pop }
    second = Thread.new { ActiveRecord::Base.connection_pool.with_connection { deliver(Message.find(id)) } }
    expect(second.join(5)).not_to be_nil
    release << true
    expect(first.join(5)).not_to be_nil
    first.value
    second.value
    expect(calls.size).to eq(1)
    expect(Message.where(followup_execution_id: business[:execution].id).count).to eq(1)
    expect(business[:execution].reload.status).to eq('dispatched')
  ensure
    release << true if release
    [first, second].compact.each { |thread| thread.join(5) }
  end

  it 'invalidates queued sending synchronously on a real incoming callback and coalesces the burst' do
    business = queued_business
    conversation = business[:conversation]
    previous_generation = FollowupConversationState.find_by!(conversation: conversation).classification_generation
    messages = Array.new(3) do |index|
      conversation.messages.create!(inbox: business[:inbox], message_type: :incoming, content: "Message part #{index}")
    end
    state = FollowupConversationState.find_by!(conversation: conversation)
    expect(state.classification_generation).to eq(previous_generation + 3)
    expect(state.latest_incoming_message_id).to eq(messages.last.id)
    expect(state.classification_due_at).to be_within(0.001).of(1.5.seconds.from_now)
    expect(business[:execution].reload.status).to eq('cancelled')
    SyntheticFollowupChannel.provider = ->(_) { raise 'must not reach provider' }
    expect { deliver(business[:execution].message) }.not_to raise_error
  end

  it 'blocks the real channel boundary after a human team takes ownership' do
    business = queued_business
    team = Team.create!(name: 'Synthetic manual team')
    business[:conversation].update!(team: team)
    SyntheticFollowupChannel.provider = ->(_) { raise 'must not reach provider' }
    expect { deliver(business[:execution].message) }.not_to raise_error
    expect(business[:execution].reload.status).to eq('cancelled')
  end

  %w[conversation contact].each do |kind|
    it "invalidates sending and restarts debounce when selected #{kind} context changes" do
      business = build_followup_business
      policy = business[:campaign].policy.deep_dup
      policy['snapshot_context'] = {
        'stage_key' => 'options_shared',
        'fields' => [{ 'key' => 'needs_callback', 'source' => "#{kind}.custom_attributes",
                       'field' => 'needs_callback', 'type' => 'boolean' }]
      }
      business[:campaign].update!(policy: policy, policy_version: 'context-v2')
      business[:evidence] = Followups::EvidenceApproval.new(
        campaign: business[:campaign], conversation: business[:conversation], pipeline_item: business[:item],
        incoming: business[:incoming], anchor: business[:anchor], actor: business[:user]
      ).call
      evaluate_followup(business)
      expect(business[:execution].reload.status).to eq('queued')
      state = FollowupConversationState.find_by!(conversation: business[:conversation])
      generation = state.classification_generation
      business[kind.to_sym].update!(custom_attributes: { 'needs_callback' => true })
      expect(state.reload.classification_generation).to eq(generation + 1)
      expect(state.classification_due_at).to be_within(0.001).of(1.5.seconds.from_now)
      expect(business[:execution].reload.status).to eq('cancelled')
      SyntheticFollowupChannel.provider = ->(_) { raise 'must not reach provider' }
      expect { deliver(business[:execution].message) }.not_to raise_error
    end
  end

  it 'blocks delivery on contact opt-out persisted through the label setter' do
    business = queued_business
    business[:contact].add_labels(business[:label].title)
    SyntheticFollowupChannel.provider = ->(_) { raise 'must not reach provider' }
    expect { deliver(business[:execution].message) }.not_to raise_error
    expect(business[:execution].reload.status).to eq('cancelled')
  end

  it 'keeps a timeout ambiguous and does not retry the provider on replay' do
    business = queued_business
    calls = 0
    SyntheticFollowupChannel.provider = lambda do |_|
      calls += 1
      raise Timeout::Error, 'synthetic lost response'
    end
    message = business[:execution].message
    expect { deliver(message) }.to raise_error(Timeout::Error)
    expect(business[:execution].reload.status).to eq('delivery_unknown')
    expect { deliver(message.reload) }.not_to raise_error
    expect(calls).to eq(1)
  end

  it 'requires a new 429 marker from this attempt and refuses a retry after handoff' do
    business = queued_business
    SyntheticFollowupChannel.provider = lambda do |message|
      message.update!(status: :failed, content_attributes: message.content_attributes.merge(
        'whatsapp_auto_retry_http_status' => 429, 'whatsapp_auto_retry_count' => 1,
        'whatsapp_auto_retry_token' => 'synthetic-retry-token'
      ))
      nil
    end
    message = business[:execution].message
    deliver(message)
    expect(business[:execution].reload.status).to eq('queued')
    travel 6.seconds
    business[:conversation].update!(assignee: business[:user])
    allow(SendReplyJob).to receive(:perform_now)
    Whatsapp::RetryRateLimitedMessageJob.perform_now(message.id, 1, 'synthetic-retry-token')
    expect(SendReplyJob).not_to have_received(:perform_now)
    expect(business[:execution].reload.status).to eq('cancelled')
  end

  it 'does not mistake a leftover 429 marker for a newly rejected send' do
    business = queued_business
    message = business[:execution].message
    message.update!(content_attributes: message.content_attributes.merge(
      'whatsapp_auto_retry_http_status' => 429, 'whatsapp_auto_retry_count' => 1
    ))
    SyntheticFollowupChannel.provider = ->(_) {}
    deliver(message)
    expect(business[:execution].reload.status).to eq('delivery_unknown')
  end

  it 'reconciles a late provider receipt despite Message failed being terminal' do
    business = queued_business
    SyntheticFollowupChannel.provider = ->(_) { raise Timeout::Error }
    message = business[:execution].message
    expect { deliver(message) }.to raise_error(Timeout::Error)
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    message.update_columns(status: Message.statuses[:failed], source_id: 'synthetic-late-receipt')
    # rubocop:enable Rails/SkipsModelValidations
    Messages::StatusUpdateService.new(message.reload, 'delivered').perform
    expect(business[:execution].reload.status).to eq('delivered')
    Messages::StatusUpdateService.new(message.reload, 'sent').perform
    expect(business[:execution].reload.status).to eq('delivered')
  end

  it 'leaves ordinary channel messages and their status semantics unchanged' do
    business = build_followup_business
    message = business[:conversation].messages.create!(inbox: business[:inbox], message_type: :outgoing, content: 'Ordinary synthetic reply')
    SyntheticFollowupChannel.provider = ->(_) { 'synthetic-ordinary-id' }
    deliver(message)
    expect(message.reload.source_id).to eq('synthetic-ordinary-id')
    message.update!(status: :failed)
    expect(Messages::StatusUpdateService.new(message, 'delivered').perform).to be(false)
    expect(message.reload.status).to eq('failed')
  end

  it 'starts a debounced classification when the incoming precedes creation of its stage card' do
    business = build_followup_business
    contact = Contact.create!(name: 'Second synthetic customer')
    link = ContactInbox.create!(contact: contact, inbox: business[:inbox], source_id: 'synthetic-second-link')
    conversation = Conversation.create!(contact: contact, inbox: business[:inbox], contact_inbox: link, status: :pending)
    incoming = conversation.messages.create!(inbox: business[:inbox], message_type: :incoming, content: 'I have a question')
    state = FollowupConversationState.find_by!(conversation: conversation)
    expect(state.classification_due_at).to be_nil
    PipelineItem.create!(pipeline: business[:pipeline], pipeline_stage: business[:stage], conversation: conversation)
    state.reload
    expect(state.latest_incoming_message_id).to eq(incoming.id)
    expect(state.classification_due_at).to be_within(0.001).of(1.5.seconds.from_now)
    travel 2.seconds
    evaluator = instance_double(Followups::Evaluator, call: nil)
    factory = double
    expect(factory).to receive(:call).once.and_return(evaluator)
    rows = Followups::DebouncedClassifier.new(conversation: conversation, generation: state.classification_generation,
                                              evaluator_factory: factory.method(:call)).call
    expect(rows.length).to eq(1)
    expect(conversation.messages.outgoing.count).to eq(0)
  end

  it 'stops the campaign and records an incident before sending to a mismatched conversation' do
    business = queued_business
    other = build_followup_business(name: 'Repair workshop', timezone: 'Europe/Lisbon')
    message = business[:execution].message
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    message.update_columns(conversation_id: other[:conversation].id, inbox_id: other[:inbox].id)
    # rubocop:enable Rails/SkipsModelValidations
    SyntheticFollowupChannel.provider = ->(_) { raise 'must not reach provider' }
    expect { deliver(message.reload) }.not_to raise_error
    expect(business[:campaign].reload.enabled).to be(false)
    expect(business[:execution].reload.reason).to eq('incident_message_identity_mismatch')
    expect(other[:campaign].reload.enabled).to be(true)
  end

  it 'quarantines conflicting provider references and stops only the affected campaign' do
    business = queued_business
    SyntheticFollowupChannel.provider = ->(_) { 'synthetic-first-reference' }
    message = business[:execution].message
    deliver(message)
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    message.update_columns(source_id: 'synthetic-conflicting-reference')
    # rubocop:enable Rails/SkipsModelValidations
    expect(Messages::StatusUpdateService.new(message.reload, 'delivered').perform).to be(false)
    expect(business[:campaign].reload.mode).to eq('off')
    expect(business[:execution].reload.status).to eq('delivery_unknown')
    expect(business[:execution].reason).to eq('incident_provider_reference_conflict')
  end

  it 'reconciles a provider reference persisted before a crash without sending again' do
    business = queued_business
    message = business[:execution].message
    # Inject persisted stale test state without callbacks so the safety rejection is exercised.
    # rubocop:disable Rails/SkipsModelValidations
    message.update_columns(source_id: 'synthetic-accepted-before-crash')
    # rubocop:enable Rails/SkipsModelValidations
    SyntheticFollowupChannel.provider = ->(_) { raise 'must not reach provider' }
    expect { deliver(message.reload) }.not_to raise_error
    expect(business[:execution].reload.status).to eq('dispatched')
    expect(business[:execution].external_provider_id).to eq('synthetic-accepted-before-crash')
  end
end
