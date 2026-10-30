# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../app/services/followups/snapshot_context'

RSpec.describe Followups::SnapshotContext do
  let(:config) do
    { 'stage_key' => 'estimate_offer', 'fields' => [
      { 'key' => 'service_kind', 'source' => 'conversation.custom_attributes', 'field' => 'service_kind', 'type' => 'enum', 'allowed_values' => %w[repair installation] },
      { 'key' => 'needs_callback', 'source' => 'contact.custom_attributes', 'field' => 'callback_requested', 'type' => 'boolean' }
    ] }
  end
  let(:contact) { Struct.new(:custom_attributes).new({ 'callback_requested' => false, 'private_email' => 'private@example.test' }) }
  let(:conversation) { Struct.new(:custom_attributes, :contact).new({ 'service_kind' => 'repair', 'private_note' => 'do not export' }, contact) }

  it 'exports only configured closed facts and a configured stage alias' do
    expect(described_class.new(config).call(conversation: conversation)).to eq('stage' => 'estimate_offer', 'service_kind' => 'repair', 'needs_callback' => false)
  end

  it 'keeps absence and null distinct from an actual false value' do
    conversation.custom_attributes.delete('service_kind')
    contact.custom_attributes['callback_requested'] = nil
    expect(described_class.new(config).call(conversation: conversation)).to eq('stage' => 'estimate_offer')
    contact.custom_attributes['callback_requested'] = false
    expect(described_class.new(config).call(conversation: conversation)['needs_callback']).to eq(false)
  end

  it 'rejects unapproved sources, nested paths, free text and unknown settings' do
    [config.merge('raw_sql' => 'SELECT *'), config.merge('fields' => [config['fields'][0].merge('source' => 'contact.email')]),
     config.merge('fields' => [config['fields'][0].merge('field' => 'custom_attributes.secret')]),
     config.merge('fields' => [config['fields'][0].merge('type' => 'string')]),
     config.merge('fields' => [config['fields'][0].merge('allowed_values' => ['person@example.test'])])].each do |invalid|
      expect { described_class.validate!(invalid) }.to raise_error(described_class::Invalid)
    end
  end

  it 'rejects duplicate or reserved output keys and excessive fields' do
    [config.merge('fields' => [config['fields'][0], config['fields'][0]]),
     config.merge('fields' => [config['fields'][0].merge('key' => 'stage')]),
     config.merge('fields' => Array.new(9) { |index| config['fields'][0].merge('key' => "field_#{index}") })].each do |invalid|
      expect { described_class.validate!(invalid) }.to raise_error(described_class::Invalid)
    end
  end

  it 'rejects a value outside the approved enum instead of passing raw CRM text' do
    ['person@example.test', 'other_service', { 'name' => 'Private name' }, ['repair'], 1].each do |value|
      conversation.custom_attributes['service_kind'] = value
      expect { described_class.new(config).call(conversation: conversation) }.to raise_error(described_class::InvalidValue)
    end
  end

  it 'rejects boolean strings and numeric substitutes instead of coercing them' do
    ['true', 'false', 0, 1].each do |value|
      contact.custom_attributes['callback_requested'] = value
      expect { described_class.new(config).call(conversation: conversation) }.to raise_error(described_class::InvalidValue)
    end
  end

  it 'has no effect when no context selection was configured' do
    expect(described_class.new({}).call(conversation: conversation)).to eq({})
  end
end
