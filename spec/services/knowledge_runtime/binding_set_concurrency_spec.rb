require 'rails_helper'

RSpec.describe KnowledgeRuntime::BindingSet do
  self.use_transactional_tests = false

  it 'accepts exactly one replacement at the same revision' do # rubocop:disable RSpec/ExampleLength
    scope = "race-#{SecureRandom.hex(8)}"
    agent_id = SecureRandom.uuid
    user_id = SecureRandom.uuid
    bases = %w[A B].map { |name| KnowledgeBase.create!(account_scope: scope, name: name) }
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = bases.map do |base|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          revision = described_class.replace!(account_scope: scope, agent_id: agent_id,
                                              base_ids: [base.id], expected_revision: 0, user_id: user_id)
          results << [revision, base.id]
        rescue StandardError => e
          results << e
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:join)
    outcomes = Array.new(2) { results.pop }
    successful = outcomes.select { |outcome| outcome.is_a?(Array) }
    conflicts = outcomes.select { |outcome| outcome.is_a?(KnowledgeRuntime::BindingSet::RevisionConflict) }
    expect(successful.size).to eq(1)
    expect(conflicts.size).to eq(1)
    expect(successful.first.first).to eq(1)
    expect(KnowledgeAgentBinding.where(account_scope: scope, external_agent_id: agent_id).pluck(:knowledge_base_id))
      .to eq([successful.first.last])
    expect(KnowledgeAgentAccessProfile.find_by!(account_scope: scope, external_agent_id: agent_id).revision).to eq(1)
  ensure
    KnowledgeAgentBinding.where(account_scope: scope).delete_all if scope
    KnowledgeAgentAccessProfile.where(account_scope: scope).delete_all if scope
    KnowledgeBase.where(account_scope: scope).delete_all if scope
  end
end
