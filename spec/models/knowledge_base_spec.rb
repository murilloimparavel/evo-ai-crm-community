require 'rails_helper'

RSpec.describe KnowledgeBase do
  it 'prevents a binding from crossing account boundaries' do
    base = described_class.create!(account_scope: 'a', name: 'A')
    binding = KnowledgeAgentBinding.new(account_scope: 'b', external_agent_id: SecureRandom.uuid, knowledge_base: base)
    expect(binding).not_to be_valid
  end

  it 'prevents an article from crossing account boundaries' do
    base = described_class.create!(account_scope: 'a', name: 'A')
    entry = KnowledgeEntry.new(account_scope: 'b', knowledge_base: base, title: 'Rule', body: 'Text', content_type: 'rule')
    expect(entry).not_to be_valid
  end

  it 'enforces one default and case-insensitive names per account' do
    described_class.create!(account_scope: 'a', name: 'Geral', legacy_default: true)
    expect(described_class.new(account_scope: 'a', name: 'GERAL')).not_to be_valid
    expect { described_class.create!(account_scope: 'a', name: 'Other', legacy_default: true) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
