# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::FilterService do
  describe '#conversations' do
    it 'orders by last_activity_at desc by default and paginates' do
      user = instance_double(User)
      service = described_class.new({}, user)

      relation = double('Relation')
      service.instance_variable_set(:@conversations, relation)

      # Resolvido via ConversationFinder::SORT_OPTIONS (paridade com o index),
      # que passa a direção como string 'desc'.
      expect(relation).to receive(:sort_on_last_activity_at).with('desc').and_return(relation)
      expect(relation).to receive(:page).with(1).and_return(relation)

      service.conversations
    end

    it 'honors sort_by (parity with the index) when provided' do
      user = instance_double(User)
      service = described_class.new({ sort_by: 'created_at_asc' }, user)

      relation = double('Relation')
      service.instance_variable_set(:@conversations, relation)

      expect(relation).to receive(:sort_on_created_at).with('asc').and_return(relation)
      expect(relation).to receive(:page).with(1).and_return(relation)

      service.conversations
    end
  end

  describe '#filter_payload (key aliasing)' do
    let(:user) { instance_double(User) }
    let(:rows) do
      [{ 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['open'], 'query_operator' => nil }]
    end

    it 'reads rows from :payload (upstream Chatwoot contract)' do
      service = described_class.new({ payload: rows }, user)
      expect(service.send(:filter_payload)).to eq(rows)
    end

    it 'reads rows from :filters as a compat alias for the evo frontend' do
      service = described_class.new({ filters: rows }, user)
      expect(service.send(:filter_payload)).to eq(rows)
    end

    it 'returns an empty array when neither key is provided, avoiding NoMethodError' do
      service = described_class.new({}, user)
      expect(service.send(:filter_payload)).to eq([])
      expect { service.send(:validate_query_operator) }.not_to raise_error
    end
  end

  describe '#query_builder (empty-clause handling)' do
    let(:user) { instance_double(User) }

    it 'drops rows whose built clause is empty without desyncing the operator of the next row' do
      rows = [
        { 'attribute_key' => 'a', 'filter_operator' => 'equal_to', 'values' => ['x'], 'query_operator' => nil },
        { 'attribute_key' => 'b', 'filter_operator' => 'equal_to', 'values' => ['y'], 'query_operator' => 'OR' },
        { 'attribute_key' => 'c', 'filter_operator' => 'equal_to', 'values' => ['z'], 'query_operator' => 'AND' }
      ]
      service = described_class.new({ filters: rows }, user)

      allow(service).to receive(:build_condition_query) do |_m, _q, idx|
        # Middle clause is empty (simulates a handler that returned '' on a
        # path that bypasses the InvalidAttribute guard). Last clause still
        # carries its trailing operator suffix to exercise the strip regex.
        ['c0', '', 'c2 AND'][idx]
      end

      relation = double('Relation')
      allow(service).to receive(:base_relation).and_return(relation)
      expect(relation).to receive(:where).with('c0 AND c2', anything).and_return(relation)

      service.send(:query_builder, {})
    end
  end

  describe 'urgent marker combined with advanced filters' do
    let(:channel) { Channel::Api.create! }
    let(:inbox) { Inbox.create!(name: 'Filter test inbox', channel: channel) }
    let(:contact) { Contact.create!(name: 'Filter customer', email: "filter-#{SecureRandom.hex(4)}@example.com") }
    let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
    let(:user) { instance_double(User) }
    let!(:urgent_high) { create_conversation(priority: 'high', urgent: true, created_at: 1.day.ago) }
    let!(:urgent_low) { create_conversation(priority: 'low', urgent: true, created_at: 1.day.ago) }
    let!(:regular_high) { create_conversation(priority: 'high', urgent: false, created_at: 1.day.ago) }
    let!(:old_urgent_high) { create_conversation(priority: 'high', urgent: true, created_at: 5.days.ago) }

    def create_conversation(priority:, urgent:, created_at:)
      Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox,
                           priority: priority, created_at: created_at,
                           custom_attributes: urgent ? { 'urgent_followup' => true } : {})
    end

    def row(key, operator, values)
      { 'attribute_key' => key, 'filter_operator' => operator, 'values' => values, 'query_operator' => 'AND' }
        .with_indifferent_access
    end

    def filtered_ids(*rows)
      service = described_class.new({ filters: rows }, user)
      ids = [urgent_high, urgent_low, regular_high, old_urgent_high].map(&:id)
      allow(service).to receive(:base_relation).and_return(Conversation.where(id: ids))
      service.send(:query_builder, service.instance_variable_get(:@filters)['conversations']).pluck(:id)
    end

    it 'combines urgent with priority without losing either condition' do
      expect(filtered_ids(row('urgent_followup', 'equal_to', ['true']), row('priority', 'equal_to', ['high'])))
        .to contain_exactly(urgent_high.id, old_urgent_high.id)
    end

    it 'combines urgent with creation date' do
      expect(filtered_ids(row('urgent_followup', 'equal_to', ['true']),
                          row('created_at', 'is_greater_than', [3.days.ago.to_date.iso8601])))
        .to contain_exactly(urgent_high.id, urgent_low.id)
    end

    it 'applies urgent, priority and date together' do
      expect(filtered_ids(row('urgent_followup', 'equal_to', ['true']), row('priority', 'equal_to', ['high']),
                          row('created_at', 'is_greater_than', [3.days.ago.to_date.iso8601])))
        .to contain_exactly(urgent_high.id)
    end

    it 'treats an absent marker as false' do
      expect(filtered_ids(row('urgent_followup', 'equal_to', ['false']))).to contain_exactly(regular_high.id)
    end
  end
end
