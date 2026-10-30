require 'rails_helper'
require_relative '../../../support/followup_engine_fixtures'

RSpec.describe 'Followup anchor evidence API', type: :request do
  include FollowupEngineFixtures
  let!(:business) { build_followup_business }

  before do
    allow(SendReplyJob).to receive(:perform_later)
    operator = business[:user]
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = operator
      Current.service_authenticated = false
    end
    allow_any_instance_of(PipelinePolicy).to receive(:update_items?).and_return(true)
  end
  after { Current.reset }

  def parameters
    { campaign_id: business[:campaign].id, conversation_id: business[:conversation].id, pipeline_item_id: business[:item].id, source_incoming_message_id: business[:incoming].id, anchor_message_id: business[:anchor].id, anchor_digest: Followups::EvidenceApproval.digest(business[:anchor]) }
  end

  it 'previews exact identity and writes only metadata without taking over the conversation' do
    get '/api/v1/followup_evidences/preview', params: parameters
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['conversation_id']).to eq(business[:conversation].id)
    expect(response.parsed_body['anchor_digest']).to eq(parameters[:anchor_digest])
    expect { post '/api/v1/followup_evidences', params: parameters, as: :json }.not_to change(Message, :count)
    expect(response).to have_http_status(:created)
    expect(business[:conversation].reload.assignee_id).to be_nil
    expect(business[:conversation].team_id).to be_nil
    expect(business[:item].reload.pipeline_stage_id).to eq(business[:stage].id)
  end

  it 'rejects generic service tokens even if they otherwise bypass pipeline authorization' do
    operator = business[:user]
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = operator
      Current.service_authenticated = true
    end
    post '/api/v1/followup_evidences', params: parameters, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'enforces existing pipeline write permission' do
    allow_any_instance_of(PipelinePolicy).to receive(:update_items?).and_return(false)
    post '/api/v1/followup_evidences', params: parameters, as: :json
    # The existing application exception wrapper maps Pundit denial to 401.
    expect(response).to have_http_status(:unauthorized)
  end

  it 'rejects changed content since operator preview' do
    stale = parameters
    business[:anchor].update!(content: 'Content changed after preview')
    post '/api/v1/followup_evidences', params: stale, as: :json
    expect(response).to have_http_status(:conflict)
  end

  it 'rejects another conversation identity before approving any evidence' do
    another = build_followup_business(name: 'Repair workshop', timezone: 'Europe/Lisbon', stage_name: 'Estimate delivered', label_name: 'no_contact')
    post '/api/v1/followup_evidences', params: parameters.merge(conversation_id: another[:conversation].id), as: :json
    expect(response).to have_http_status(:not_found)
  end
end
