require 'rails_helper'

RSpec.describe PipelineClassification::Catalog do
  let(:user) { User.create!(name: 'Catalog owner', email: "catalog-#{SecureRandom.hex(5)}@example.test") }
  let(:pipeline) { Pipeline.create!(name: "Catalog #{SecureRandom.hex(4)}", created_by: user) }
  let!(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'Considering', position: 1) }
  let(:editor) { PipelineClassification::Editor.new(pipeline: pipeline, actor: user) }

  def payload
    profile = described_class::DEFAULT_STAGE.deep_dup.merge(
      'classification_enabled' => true, 'definition' => 'Customer is considering the options',
      'entry_criteria' => ['Customer has asked about the options']
    )
    { 'classification' => described_class::DEFAULT_PROFILE.deep_dup.merge('purpose' => 'Understand customer intent'),
      'stages' => [{ 'id' => stage.id, 'classification_profile' => profile }] }
  end

  def save_catalog(payload_value = payload)
    editor.save!(payload: payload_value, expected_hash: described_class.new(pipeline.reload).hash)
  end

  it 'defaults to OFF without importing descriptions or legacy executable rules' do
    pipeline.update!(description: 'Legacy purpose')
    stage.update!(automation_rules: { 'description' => 'Legacy criteria', 'rules' => [{ 'trigger' => 'inactivity' }] })
    data = described_class.new(pipeline).snapshot
    expect(data.dig('classification', 'enabled')).to be(false)
    expect(data.dig('classification', 'purpose')).to eq('')
    expect(data['stages'][0].dig('classification_profile', 'definition')).to eq('')
  end

  it 'uses canonical key order and stable stage IDs independent of visual position/color' do
    save_catalog
    before = described_class.new(pipeline.reload).hash
    stage.update!(position: 3, color: '#112233')
    expect(described_class.new(pipeline.reload).hash).to eq(before)
    reordered = payload.transform_values { |value| value.is_a?(Hash) ? value.to_a.reverse.to_h : value }
    expect(described_class.new(pipeline, payload: reordered).hash).to eq(before)
  end

  it 'hashes semantic stage renames and explicit criteria' do
    save_catalog
    before = described_class.new(pipeline.reload).hash
    stage.update!(name: 'Decision pending')
    expect(described_class.new(pipeline.reload).hash).not_to eq(before)
  end

  it 'saves profiles separately and preserves legacy rules and human descriptions' do
    stage.update!(automation_rules: { 'description' => 'Human description', 'rules' => [{ 'trigger' => 'inactivity' }] })
    save_catalog
    expect(stage.reload.classification_profile['definition']).to eq('Customer is considering the options')
    expect(stage.automation_rules['description']).to eq('Human description')
    expect(stage.automation_rules['rules']).to eq([{ 'trigger' => 'inactivity' }])
  end

  it 'rejects stale editors before overwriting any stage' do
    initial = described_class.new(pipeline).hash
    save_catalog
    expect { editor.save!(payload: payload, expected_hash: initial) }.to raise_error(described_class::Conflict)
  end

  it 'publishes immutable aggregate revisions and invalidates prior approval when dirty' do
    save_catalog
    revision = editor.publish!(expected_hash: described_class.new(pipeline.reload).hash)
    expect(revision.catalog_version).to eq(1)
    expect { revision.update!(catalog_hash: 'changed') }.to raise_error(ActiveRecord::ReadOnlyRecord)
    revision.reload
    expect(editor.publish!(expected_hash: revision.catalog_hash).id).to eq(revision.id)
    changed = payload
    changed['classification']['purpose'] = 'Understand support needs'
    save_catalog(changed)
    expect(described_class.new(pipeline.reload).representation['dirty']).to be(true)
    expect(PipelineClassificationCatalog.find(revision.id).snapshot.dig('classification', 'purpose')).to eq('Understand customer intent')
    expect(editor.publish!(expected_hash: described_class.new(pipeline.reload).hash).catalog_version).to eq(2)
  end

  it 'compiles one closed question with opaque aliases plus two explicit abstention options' do
    save_catalog
    compiled = described_class.new(pipeline.reload).compiled
    expect(compiled['questions'].keys).to eq(['stage_candidate'])
    expect(compiled['aliases'].values).to eq([stage.id])
    expect(compiled.dig('questions', 'stage_candidate', 'criteria').keys).to contain_exactly('stage_1', 'unclear', 'no_candidate')
    expect(compiled.dig('questions', 'stage_candidate', 'instructions')).to include('never proves payment')
    expect(compiled.to_json).not_to include('trigger_value')
  end

  it 'rejects foreign stages, invalid sources, free expressions, and unknown profile keys' do
    bad = payload
    bad['stages'][0]['id'] = SecureRandom.uuid
    expect { save_catalog(bad) }.to raise_error(described_class::Invalid, /foreign stage/)
    bad = payload
    bad['classification']['context_sources'] =
      { 'fields' => [{ 'key' => 'paid', 'source' => 'pms.financial', 'field' => 'paid', 'type' => 'boolean' }] }
    expect { save_catalog(bad) }.to raise_error(described_class::Invalid, /context_sources/)
    bad = payload
    bad['classification']['sql'] = 'select secret'
    expect { save_catalog(bad) }.to raise_error(described_class::Invalid, /unsupported/)
  end

  it 'rejects overlarge catalogs locally without transport' do
    bad = payload
    bad['stages'][0]['classification_profile']['entry_criteria'] = Array.new(9, 'customer asks')
    expect { save_catalog(bad) }.to raise_error(described_class::Invalid)
  end

  it 'does not enable observation without independently approved installation settings' do
    bad = payload
    bad['classification'].merge!('enabled' => true, 'mode' => 'observe')
    expect { save_catalog(bad) }.to raise_error(described_class::Invalid)
    expect(pipeline.reload.config.to_h.dig('classification', 'enabled')).not_to be(true)
  end
end
