# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'WhatsApp Cloud template definitions API', type: :request do
  let(:user) { User.create!(name: 'Template QA', email: "template-qa-#{SecureRandom.hex(4)}@example.com") }

  def login_as(user, *granted)
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = user
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_service, _user_id, permission|
      granted.include?(permission)
    end
  end

  after { Current.reset }

  it 'requires message_templates.read for WABA targets' do
    login_as(user)

    get '/api/v1/whatsapp_template_definitions/targets', as: :json

    expect(response).to have_http_status(:forbidden)
  end

  it 'deduplicates inboxes by WABA and returns no channel credentials' do
    login_as(user, 'message_templates.read')
    waba_id = "waba_#{SecureRandom.hex(4)}"
    channels = 2.times.map do
      channel = Channel::Whatsapp.new(
        provider: 'whatsapp_cloud',
        phone_number: "+1555#{SecureRandom.hex(3)}",
        provider_config: { 'waba_id' => waba_id, 'api_key' => 'must-not-leak' }
      )
      channel.save!(validate: false)
      Inbox.create!(channel: channel, name: "QA #{SecureRandom.hex(3)}")
      channel
    end

    get '/api/v1/whatsapp_template_definitions/targets', as: :json

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    target = body.fetch('data').find { |item| item['waba_id'] == waba_id }
    expect(target.fetch('inboxes').length).to eq(2)
    expect(target.fetch('inboxes').map { |item| item['inbox_id'] }).to match_array(channels.map { |channel| channel.inbox.id })
    expect(response.body).not_to include('must-not-leak')
  end

  it 'creates an authorized reusable definition without binding it to a channel' do
    login_as(user, 'message_templates.manage')
    attributes = {
      name: "qa_#{SecureRandom.hex(4)}",
      language: 'pt_BR',
      category: 'UTILITY',
      content: 'Oi {{nome}}',
      components: [{ type: 'BODY', text: 'Oi {{nome}}' }],
      variables: [{ name: 'nome', example: 'Ana', required: true }]
    }

    post '/api/v1/whatsapp_template_definitions', params: { definition: attributes }, as: :json

    expect(response).to have_http_status(:created)
    definition = WhatsappTemplateDefinition.find(JSON.parse(response.body).dig('data', 'id'))
    expect(definition).to have_attributes(name: attributes[:name], category: 'UTILITY')
  end

  it 'allows correcting and retrying a definition after a failed submission without a Meta ID' do
    login_as(user, 'message_templates.manage')
    definition = WhatsappTemplateDefinition.create!(
      name: "qa_#{SecureRandom.hex(4)}", language: 'pt_BR', category: 'UTILITY', content: 'Oi {{nome}}',
      components: [{ 'type' => 'BODY', 'text' => 'Oi {{nome}}' }],
      variables: [{ 'name' => 'nome', 'example' => 'Ana', 'required' => true }]
    )
    publication = definition.publications.create!(waba_id: "waba_#{SecureRandom.hex(4)}", status: 'failed',
                                                   operational_error: 'Meta rejected the submission (HTTP 400)')

    put "/api/v1/whatsapp_template_definitions/#{definition.id}",
        params: { definition: { content: 'Olá {{nome}}', components: [{ type: 'BODY', text: 'Olá {{nome}}' }] } },
        as: :json

    expect(response).to have_http_status(:ok)
    expect(definition.reload.content).to eq('Olá {{nome}}')
    expect(publication.reload).to have_attributes(status: 'not_submitted', operational_error: nil)
  end

  it 'locks definition content once a Meta template ID exists' do
    login_as(user, 'message_templates.manage')
    definition = WhatsappTemplateDefinition.create!(
      name: "qa_#{SecureRandom.hex(4)}", language: 'pt_BR', category: 'UTILITY', content: 'Olá',
      components: [{ 'type' => 'BODY', 'text' => 'Olá' }]
    )
    definition.publications.create!(waba_id: "waba_#{SecureRandom.hex(4)}", external_template_id: 'meta-template-123',
                                    status: 'pending')

    put "/api/v1/whatsapp_template_definitions/#{definition.id}",
        params: { definition: { content: 'Olá de novo', components: [{ type: 'BODY', text: 'Olá de novo' }] } },
        as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(definition.reload.content).to eq('Olá')
  end
end
