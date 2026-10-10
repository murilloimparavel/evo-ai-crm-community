# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::TemplatePublicationService do
  let(:definition) do
    WhatsappTemplateDefinition.create!(name: "notice_#{SecureRandom.hex(3)}", language: 'pt_BR',
                                       category: 'UTILITY', content: 'Olá {{customer_name}}',
                                       components: [{ 'type' => 'BODY', 'text' => 'Olá {{customer_name}}' }],
                                       variables: [{ 'name' => 'customer_name', 'example' => 'Ana', 'required' => true }])
  end

  it 'creates a named Meta payload with the declared example' do
    service = described_class.new(definition: definition, waba_id: 'waba-test')
    payload = service.send(:template_payload)

    expect(payload['parameter_format']).to eq('NAMED')
    expect(payload['components'].first.dig('example', 'body_text_named_params')).to eq(
      [{ 'param_name' => 'customer_name', 'example' => 'Ana' }]
    )
  end

  it 'does not submit variables without a sample value' do
    definition.update!(variables: [{ 'name' => 'customer_name', 'required' => true }])
    service = described_class.new(definition: definition, waba_id: 'waba-test')

    expect { service.send(:template_payload) }
      .to raise_error(Whatsapp::TemplatePublicationService::PublicationError, /Provide an example/)
  end

  it 'builds positional examples in placeholder order' do
    definition.update!(components: [{ 'type' => 'BODY', 'text' => 'Olá {{2}}, protocolo {{1}}' }],
                       variables: [{ 'name' => '2', 'example' => 'Bia' }, { 'name' => '1', 'example' => '42' }])
    payload = described_class.new(definition: definition, waba_id: 'waba-test').send(:template_payload)

    expect(payload['parameter_format']).to eq('POSITIONAL')
    expect(payload['components'].first.dig('example', 'body_text')).to eq([['42', 'Bia']])
  end

  it 'rejects positional placeholders with gaps' do
    definition.assign_attributes(components: [{ 'type' => 'BODY', 'text' => 'Olá {{2}}' }],
                                 variables: [{ 'name' => '2', 'example' => 'Bia' }])

    expect(definition).not_to be_valid
    expect(definition.errors[:components].join).to include('numbered consecutively')
  end

  it 'keeps named parameters and their examples in Meta sync component processing' do
    provider = Whatsapp::Providers::WhatsappCloudService.allocate

    components = provider.send(:process_template_components, [
      { 'type' => 'BODY', 'text' => 'Olá {{customer_name}}' }
    ])

    expect(components.first.dig('example', 'body_text_named_params')).to eq(
      [{ 'param_name' => 'customer_name', 'example' => 'Example' }]
    )
  end

  it 'does not include the Meta response body in parsing fallback errors' do
    provider = Whatsapp::Providers::WhatsappCloudService.allocate
    response = instance_double(HTTParty::Response, parsed_response: nil, code: 400,
                               body: 'token=must-not-leak')

    expect(provider.send(:parse_whatsapp_error, response)).not_to include('must-not-leak')
  end

  it 'submits a definition only once per WABA, even when the publish request repeats' do
    channel = Channel::Whatsapp.new(provider: 'whatsapp_cloud', phone_number: "+1555#{SecureRandom.hex(3)}",
                                    provider_config: { 'waba_id' => 'waba-repeat-test' })
    channel.save!(validate: false)
    template = MessageTemplate.create!(name: definition.name, content: definition.content, language: definition.language,
                                       category: definition.category, channel: channel,
                                       components: { 'body' => definition.components.first },
                                       metadata: { 'external_id' => 'meta-template-1' },
                                       settings: { 'status' => 'PENDING' })
    provider = instance_double(Whatsapp::Providers::WhatsappCloudService, create_template: template)
    service = described_class.new(definition: definition, waba_id: 'waba-repeat-test')
    allow(service).to receive(:cloud_channels).and_return([channel])
    allow(channel).to receive(:provider_service).and_return(provider)

    expect { service.call }.not_to raise_error
    expect { service.call }.not_to raise_error
    expect(provider).to have_received(:create_template).once
    expect(definition.publications.where(waba_id: 'waba-repeat-test').count).to eq(1)
  end
end
