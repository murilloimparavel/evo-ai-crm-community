# frozen_string_literal: true

require 'rails_helper'

RSpec.describe KnowledgeRuntime::Retrieval do
  let(:agent_id) { SecureRandom.uuid }
  let(:other_agent) { SecureRandom.uuid }
  let!(:base_a) { KnowledgeBase.create!(account_scope: 'a', name: 'A') }
  let!(:base_b) { KnowledgeBase.create!(account_scope: 'a', name: 'B') }
  let!(:base_other) { KnowledgeBase.create!(account_scope: 'b', name: 'C') }

  def entry(base, title, status = 'published')
    KnowledgeEntry.create!(account_scope: base.account_scope, knowledge_base: base, title: title,
                           body: 'piscina aquecida', content_type: 'faq', status: status)
  end

  def bind(base, agent, enabled: true)
    KnowledgeAgentBinding.create!(account_scope: base.account_scope, knowledge_base: base,
                                  external_agent_id: agent, enabled: enabled)
  end

  it 'filters scope, current bindings and publication before applying the limit' do
    accessible = entry(base_a, 'Piscina visível')
    entry(base_a, 'Piscina rascunho', 'draft')
    entry(base_b, 'Piscina privada')
    entry(base_other, 'Piscina estrangeira')
    bind(base_a, agent_id)
    bind(base_b, other_agent)
    bind(base_other, agent_id)
    results = described_class.call(account_scope: 'a', agent_id: agent_id, query: 'piscina', limit: 1)
    expect(results.map { |item| item[:id] }).to eq([accessible.id])
    expect(described_class.call(account_scope: 'a', agent_id: SecureRandom.uuid, query: 'piscina')).to be_empty
  end

  it 'honors disabled bindings and archived bases on the next search' do
    entry(base_a, 'Piscina visível')
    binding = bind(base_a, agent_id)
    expect(described_class.call(account_scope: 'a', agent_id: agent_id, query: 'piscina').size).to eq(1)
    binding.update!(enabled: false)
    expect(described_class.call(account_scope: 'a', agent_id: agent_id, query: 'piscina')).to be_empty
    binding.update!(enabled: true)
    base_a.update!(status: 'archived')
    expect(described_class.call(account_scope: 'a', agent_id: agent_id, query: 'piscina')).to be_empty
  end

  it 'rejects invalid inputs instead of broadening access' do
    expect { described_class.call(account_scope: 'a', agent_id: 'invalid', query: 'piscina') }
      .to raise_error(described_class::InvalidRequest)
    expect { described_class.call(account_scope: '', agent_id: agent_id, query: 'piscina') }
      .to raise_error(described_class::InvalidRequest)
    expect { described_class.call(account_scope: 'a', agent_id: agent_id, query: 'piscina', limit: 0) }
      .to raise_error(described_class::InvalidRequest)
  end
end
