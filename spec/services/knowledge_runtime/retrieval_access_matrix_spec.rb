# frozen_string_literal: true

require 'rails_helper'

RSpec.describe KnowledgeRuntime::Retrieval do
  it 'enforces distinct bindings and immediate revocation across accounts' do # rubocop:disable RSpec/ExampleLength
    scope = 'matrix-a'
    scope_b = 'matrix-b'
    agents = Array.new(4) { SecureRandom.uuid }
    actor = SecureRandom.uuid
    first = KnowledgeBase.create!(account_scope: scope, name: 'Primeira')
    second = KnowledgeBase.create!(account_scope: scope, name: 'Segunda')
    foreign = KnowledgeBase.create!(account_scope: scope_b, name: 'Externa')
    entries = [first, second, foreign].map do |base|
      KnowledgeEntry.create!(account_scope: base.account_scope, knowledge_base: base, title: 'Piscina',
                             body: 'Piscina aquecida', content_type: 'faq', status: 'published')
    end
    [[agents[0], [first.id]], [agents[1], [second.id]], [agents[2], [first.id, second.id]]].each do |agent, ids|
      KnowledgeRuntime::BindingSet.replace!(account_scope: scope, agent_id: agent, base_ids: ids,
                                            expected_revision: 0, user_id: actor)
    end
    KnowledgeRuntime::BindingSet.replace!(account_scope: scope_b, agent_id: agents[0], base_ids: [foreign.id],
                                          expected_revision: 0, user_id: actor)
    lookup = ->(account, agent) { described_class.call(account_scope: account, agent_id: agent, query: 'piscina').pluck(:id) }
    expect(lookup.call(scope, agents[0])).to contain_exactly(entries[0].id)
    expect(lookup.call(scope, agents[1])).to contain_exactly(entries[1].id)
    expect(lookup.call(scope, agents[2])).to contain_exactly(entries[0].id, entries[1].id)
    expect(lookup.call(scope, agents[3])).to be_empty
    expect(lookup.call(scope_b, agents[0])).to contain_exactly(entries[2].id)
    KnowledgeRuntime::BindingSet.replace!(account_scope: scope, agent_id: agents[2], base_ids: [second.id],
                                          expected_revision: 1, user_id: actor)
    expect(lookup.call(scope, agents[2])).to contain_exactly(entries[1].id)
    entries[1].update!(status: 'archived')
    expect(lookup.call(scope, agents[2])).to be_empty
  end
end
