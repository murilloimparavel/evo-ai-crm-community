require 'rails_helper'

RSpec.describe KnowledgeEntry, type: :model do
  it 'indexes only published matching knowledge' do
    published = described_class.create!(title: 'Endereço da empresa', body: 'Rua das Flores',
                                        content_type: 'company', account_scope: 'community', status: 'published')
    described_class.create!(title: 'Endereço antigo', body: 'Rua desativada',
                            content_type: 'company', account_scope: 'community', status: 'draft')

    expect(described_class.search_published('endereço').pluck(:id)).to eq([published.id])
  end

  it 'rejects unsupported content types and malformed tags' do
    entry = described_class.new(title: 'Teste', body: 'Texto', content_type: 'price', tags: ['ok', 1])
    expect(entry).not_to be_valid
  end
end
