require 'rails_helper'
require 'database_cleaner/active_record'
require 'timeout'
require_relative '../../support/followup_engine_fixtures'

RSpec.describe 'Followup refresh racing with incoming' do
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
    allow(Followups::DebouncedClassificationJob).to receive_message_chain(:set, :perform_later)
  end
  after { travel_back }

  it 'does not overwrite the new source or deadline with the source captured by refresh' do
    business = build_followup_business
    captured = Queue.new
    release = Queue.new
    started = Queue.new
    result = Queue.new
    errors = Queue.new
    allow(Followups::Eligibility).to receive(:latest_incoming).and_wrap_original do |original, conversation|
      value = original.call(conversation)
      if Thread.current[:followup_refresh_probe]
        captured << true
        release.pop
      end
      value
    end
    refresh = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:followup_refresh_probe] = true
        Followups::DebounceCoordinator.refresh!(conversation: Conversation.find(business[:conversation].id), reason: 'policy_changed')
      rescue StandardError => error
        errors << error
      end
    end
    Timeout.timeout(5) { captured.pop }
    incoming = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << true
        conversation = Conversation.find(business[:conversation].id)
        message = conversation.messages.create!(inbox_id: business[:inbox].id, message_type: :incoming, content: 'New message during refresh')
        result << message.id
      rescue StandardError => error
        errors << error
      end
    end
    Timeout.timeout(5) { started.pop }
    release << true
    expect(refresh.join(5)).not_to be_nil
    expect(incoming.join(5)).not_to be_nil
    raise errors.pop unless errors.empty?
    id = result.pop
    state = FollowupConversationState.find_by!(conversation_id: business[:conversation].id)
    expect(state.latest_incoming_message_id).to eq(id)
    expect(state.classification_due_at).to be_present
    expect(state.classification_generation).to be >= 2
  ensure
    release << true if release
    refresh&.join(5)
    incoming&.join(5)
  end
end
