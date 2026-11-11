require 'rails_helper'

RSpec.describe KnowledgeRuntime::BindingSet do
  self.use_transactional_tests = false

  it 'rejects a binding replacement when an archival holding the base lock commits first' do # rubocop:disable RSpec/ExampleLength
    scope = "binding-archive-race-#{SecureRandom.hex(8)}"
    agent_id = SecureRandom.uuid
    user_id = SecureRandom.uuid
    active_base = KnowledgeBase.create!(account_scope: scope, name: 'Existing')
    archived_base = KnowledgeBase.create!(account_scope: scope, name: 'Archiving')
    described_class.replace!(account_scope: scope, agent_id: agent_id, base_ids: [active_base.id],
                             expected_revision: 0, user_id: user_id)

    locked = Queue.new
    release = Queue.new
    started = Queue.new
    result = Queue.new
    archiver = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        KnowledgeBase.transaction do
          KnowledgeBase.lock.find(archived_base.id).update!(status: 'archived')
          locked << true
          release.pop
        end
      end
    rescue StandardError => e
      locked << e
    end
    lock_result = locked.pop
    raise lock_result if lock_result.is_a?(Exception)

    replacer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << true
        described_class.replace!(account_scope: scope, agent_id: agent_id, base_ids: [archived_base.id],
                                 expected_revision: 1, user_id: user_id)
        result << :unexpected_success
      rescue StandardError => e
        result << e
      end
    end
    started.pop
    release << true
    [archiver, replacer].each(&:join)

    expect(result.pop).to be_a(KnowledgeRuntime::BindingSet::InvalidSelection)
    expect(KnowledgeAgentAccessProfile.find_by!(account_scope: scope, external_agent_id: agent_id).revision).to eq(1)
    expect(KnowledgeAgentBinding.where(account_scope: scope, external_agent_id: agent_id).pluck(:knowledge_base_id)).to eq([active_base.id])
  ensure
    release << true if release && archiver&.alive?
    [archiver, replacer].compact.each(&:join)
    KnowledgeAgentBinding.where(account_scope: scope).delete_all if scope
    KnowledgeAgentAccessProfile.where(account_scope: scope).delete_all if scope
    KnowledgeBase.where(account_scope: scope).delete_all if scope
  end
end
