# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# The global OpenAI event processor mutates nothing but spends provider
# credits and exposes AI capabilities; it demands integrations.execute — the
# same key hooks#process_event enforces.
RSpec.describe 'Integrations OpenAI RBAC', type: :request do
  let(:user) { User.create!(name: 'Perm Probe', email: "probe-#{SecureRandom.hex(4)}@example.com") }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
  end

  after { Current.reset }

  def grant_permissions(*granted)
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_service, _user_id, permission|
      granted.include?(permission)
    end
  end

  describe 'POST /api/v1/integrations/openai/process_event' do
    it 'denies a user without integrations.execute' do
      grant_permissions('integrations.read', 'ai_agents.update')

      post '/api/v1/integrations/openai/process_event',
           params: { event: { name: 'rephrase', data: { content: 'hi' } } }, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'processes the event for a holder of integrations.execute' do
      grant_permissions('integrations.execute')
      processor = instance_double(Integrations::Openai::GlobalProcessorService,
                                  perform: { message: 'rephrased' })
      allow(Integrations::Openai::GlobalProcessorService).to receive(:new).and_return(processor)

      post '/api/v1/integrations/openai/process_event',
           params: { event: { name: 'rephrase', data: { content: 'hi' } } }, as: :json

      expect(response).to have_http_status(:ok)
    end

    it 'returns provider errors as a gateway error with actionable detail' do
      grant_permissions('integrations.execute')
      processor = instance_double(Integrations::Openai::GlobalProcessorService,
                                  perform: { error: { 'error' => { 'message' => 'model does not support chat' } },
                                             error_code: 400 })
      allow(Integrations::Openai::GlobalProcessorService).to receive(:new).and_return(processor)

      post '/api/v1/integrations/openai/process_event',
           params: { event: { name: 'rephrase', data: { content: 'hi' } } }, as: :json

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body['error']).to eq('model does not support chat')
    end
  end
end
