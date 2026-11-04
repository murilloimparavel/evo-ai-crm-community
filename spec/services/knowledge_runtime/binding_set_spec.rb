require 'rails_helper'

RSpec.describe KnowledgeRuntime::BindingSet do
  let(:agent_id) { SecureRandom.uuid }
  let(:user_id) { SecureRandom.uuid }
  let!(:base_a) { KnowledgeBase.create!(account_scope: 'a', name: 'A') }
  let!(:base_b) { KnowledgeBase.create!(account_scope: 'a', name: 'B') }
  let!(:other) { KnowledgeBase.create!(account_scope: 'b', name: 'Other') }

  def replace(ids, revision)
    described_class.replace!(account_scope: 'a', agent_id: agent_id, base_ids: ids,
                             expected_revision: revision, user_id: user_id)
  end

  it 'replaces the full set atomically and rejects a stale revision' do
    expect(replace([base_a.id, base_b.id], 0)).to eq(1)
    expect(replace([base_b.id], 1)).to eq(2)
    expect { replace([base_a.id], 1) }.to raise_error(described_class::RevisionConflict)
    expect(KnowledgeAgentBinding.where(account_scope: 'a', external_agent_id: agent_id).pluck(:knowledge_base_id)).to eq([base_b.id])
    expect(KnowledgeAgentAccessProfile.find_by!(account_scope: 'a', external_agent_id: agent_id).revision).to eq(2)
  end

  it 'rolls back the entire selection when a base belongs to another scope or is archived' do
    expect(replace([base_a.id], 0)).to eq(1)
    expect { replace([base_b.id, other.id], 1) }.to raise_error(described_class::InvalidSelection)
    base_b.update!(status: 'archived')
    expect { replace([base_b.id], 1) }.to raise_error(described_class::InvalidSelection)
    expect(KnowledgeAgentBinding.where(account_scope: 'a', external_agent_id: agent_id).pluck(:knowledge_base_id)).to eq([base_a.id])
    expect(KnowledgeAgentAccessProfile.find_by!(account_scope: 'a', external_agent_id: agent_id).revision).to eq(1)
  end

  it 'rejects malformed and duplicate IDs and allows removing all bindings' do
    expect { replace([base_a.id, base_a.id.upcase], 0) }.to raise_error(described_class::InvalidSelection)
    expect { replace(['not-a-uuid'], 0) }.to raise_error(described_class::InvalidSelection)
    expect(replace([base_a.id], 0)).to eq(1)
    expect(replace([], 1)).to eq(2)
    expect(KnowledgeAgentBinding.where(account_scope: 'a', external_agent_id: agent_id)).to be_empty
  end
end
