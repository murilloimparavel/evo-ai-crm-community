# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Pipeline item identity on writes', type: :request do
  let(:user) { User.create!(name: 'Identity probe', email: "identity-#{SecureRandom.hex(4)}@example.com") }
  let(:pipeline) { Pipeline.create!(name: 'Identity sales', pipeline_type: 'sales', created_by: user) }
  let!(:source_stage) { pipeline.pipeline_stages.create!(name: 'Source', position: 1) }
  let!(:target_stage) { pipeline.pipeline_stages.create!(name: 'Target', position: 2) }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://identity.example.com') }
  let(:inbox) { Inbox.create!(name: 'Identity inbox', channel: channel) }
  let!(:unrelated) { build_conversation(display_id: 2) }
  let!(:unrelated_card) { build_card(unrelated) }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(PipelinePolicy).to receive(:view?).and_return(true)
    allow_any_instance_of(PipelinePolicy).to receive(:update?).and_return(true)
    allow_any_instance_of(PipelinePolicy).to receive(:update_items?).and_return(true)
  end

  after { Current.reset }

  def build_conversation(**attributes)
    contact = Contact.create!(name: "Synthetic #{SecureRandom.hex(4)}")
    link = ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8))
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: link, **attributes)
  end

  def build_card(conversation, **attributes)
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: source_stage, conversation: conversation, **attributes)
  end

  def move(identifier, stage: target_stage, pipeline_id: pipeline.id)
    patch "/api/v1/pipelines/#{pipeline_id}/pipeline_items/#{identifier}/move_to_stage",
          params: { new_stage_id: stage.id }, as: :json
  end

  def create_card(identifier)
    post "/api/v1/pipelines/#{pipeline.id}/pipeline_items",
         params: { type: 'conversation', item_id: identifier, pipeline_stage_id: target_stage.id }, as: :json
  end

  def relocate(identifier, stage: target_stage)
    patch "/api/v1/pipelines/#{pipeline.id}/pipeline_items/move_conversation",
          params: { conversation_id: identifier, pipeline_stage_id: stage.id }, as: :json
  end

  def expect_unrelated_untouched
    expect(unrelated_card.reload.pipeline_stage_id).to eq(source_stage.id)
    expect(unrelated_card.pipeline_id).to eq(pipeline.id)
  end

  describe 'legacy conversation aliases for card writes' do
    it 'identifies a missing card with a structured recovery reason' do
      conversation = build_conversation

      expect { move(conversation.id) }.not_to change(PipelineItem, :count)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig('error', 'code')).to eq(ApiErrorCodes::RESOURCE_NOT_FOUND)
      expect(response.parsed_body.dig('error', 'details', 'reason')).to eq('pipeline_item_not_found')
      expect_unrelated_untouched
    end

    it 'does not describe an invalid target stage as a missing card' do
      conversation = build_conversation
      card = build_card(conversation)
      other = Pipeline.create!(name: 'Another board', pipeline_type: 'sales', created_by: user)
      other_stage = other.pipeline_stages.create!(name: 'Elsewhere', position: 1)

      expect { move(conversation.id, stage: other_stage) }.not_to change(StageMovement, :count)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig('error', 'details', 'reason')).not_to eq('pipeline_item_not_found')
      expect(card.reload.pipeline_stage_id).to eq(source_stage.id)
      expect_unrelated_untouched
    end

    %w[2a000000-0000-4000-8000-000000000001 80000000-0000-4000-8000-000000000001 aa000000-0000-4000-8000-000000000001].each do |uuid|
      it "moves the exact conversation UUID #{uuid}" do
        conversation = build_conversation(id: uuid)
        card = build_card(conversation)

        move(uuid)

        expect(response).to have_http_status(:ok)
        expect(card.reload.pipeline_stage_id).to eq(target_stage.id)
        expect(response.parsed_body.dig('data', 'pipeline_item', 'conversation_id')).to eq(uuid)
        expect_unrelated_untouched
      end
    end

    it 'accepts a complete positive public number and returns both conversation identities' do
      conversation = build_conversation(display_id: 21)
      card = build_card(conversation)

      move('21')

      expect(response).to have_http_status(:ok)
      expect(card.reload.pipeline_stage_id).to eq(target_stage.id)
      expect(response.parsed_body.dig('data', 'pipeline_item', 'conversation_id')).to eq(conversation.id)
      expect(response.parsed_body.dig('data', 'pipeline_item', 'conversation_display_id')).to eq(21)
      expect_unrelated_untouched
    end

    it 'accepts the exact card UUID' do
      conversation = build_conversation
      card = build_card(conversation)

      move(card.id)

      expect(response).to have_http_status(:ok)
      expect(card.reload.pipeline_stage_id).to eq(target_stage.id)
      expect_unrelated_untouched
    end

    it 'updates the exact UUID conversation through update_conversation' do
      conversation = build_conversation(id: '2a000000-0000-4000-8000-000000000004')
      card = build_card(conversation)

      patch "/api/v1/pipelines/#{pipeline.id}/pipeline_items/#{conversation.id}/update_conversation",
            params: { stage_id: target_stage.id, notes: 'Synthetic identity check' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(card.reload.pipeline_stage_id).to eq(target_stage.id)
      expect(card.stage_movements.pluck(:notes)).to include('Synthetic identity check')
      expect_unrelated_untouched
    end

    it 'destroys only the exact UUID conversation card' do
      conversation = build_conversation(id: '2a000000-0000-4000-8000-000000000005')
      card = build_card(conversation)

      expect do
        delete "/api/v1/pipelines/#{pipeline.id}/pipeline_items/#{conversation.id}", as: :json
      end.to change(PipelineItem, :count).by(-1)

      expect(response).to have_http_status(:ok)
      expect(PipelineItem.exists?(card.id)).to be(false)
      expect(Conversation.exists?(conversation.id)).to be(true)
      expect_unrelated_untouched
    end

    %w[2a000000-0000-4000-8000-000000009999 2garbage 2.5 2e1 -2 0 2147483648 999999999999999999999999999].each do |invalid|
      it "rejects #{invalid.inspect} without a numeric prefix fallback" do
        expect { move(invalid) }.not_to change(StageMovement, :count)

        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include(unrelated.id)
        expect_unrelated_untouched
      end
    end

    it 'does not use a card from another pipeline' do
      other = Pipeline.create!(name: 'Other', pipeline_type: 'sales', created_by: user)
      other_stage = other.pipeline_stages.create!(name: 'Other source', position: 1)
      card = PipelineItem.create!(pipeline: other, pipeline_stage: other_stage, conversation: build_conversation)

      move(card.id)

      expect(response).to have_http_status(:not_found)
      expect(card.reload.pipeline_stage_id).to eq(other_stage.id)
      expect_unrelated_untouched
    end

    it 'rejects a target stage from another pipeline' do
      other = Pipeline.create!(name: 'Other', pipeline_type: 'sales', created_by: user)
      other_stage = other.pipeline_stages.create!(name: 'Other target', position: 1)

      move(unrelated_card.id, stage: other_stage)

      expect(response).to have_http_status(:not_found)
      expect_unrelated_untouched
    end

    it 'does not fall back when the exact conversation has no card in the pipeline' do
      conversation = build_conversation(id: '2a000000-0000-4000-8000-000000000002')

      move(conversation.id)

      expect(response).to have_http_status(:not_found)
      expect_unrelated_untouched
    end

    it 'does not move an exact UUID target when card-write permission is denied' do
      conversation = build_conversation(id: '2a000000-0000-4000-8000-000000000006')
      card = build_card(conversation)
      allow_any_instance_of(PipelinePolicy).to receive(:update_items?).and_return(false)

      move(conversation.id)

      expect(response).to have_http_status(:unauthorized)
      expect(card.reload.pipeline_stage_id).to eq(source_stage.id)
      expect_unrelated_untouched
    end

    it 'rejects a UUID naming a conversation and another conversation card' do
      conversation = build_conversation
      original = build_card(conversation)
      collision = build_card(build_conversation, id: conversation.id)

      expect { move(conversation.id) }.not_to change(StageMovement, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig('error', 'message')).to include('Ambiguous')
      expect(response.parsed_body.to_json).not_to include(collision.conversation_id)
      expect(original.reload.pipeline_stage_id).to eq(source_stage.id)
      expect(collision.reload.pipeline_stage_id).to eq(source_stage.id)
      expect_unrelated_untouched
    end

    it 'selects the active journey without moving its completed history' do
      conversation = build_conversation
      history = build_card(conversation, completed_at: 2.days.ago)
      active = build_card(conversation)

      move(conversation.id)

      expect(response).to have_http_status(:ok)
      expect(active.reload.pipeline_stage_id).to eq(target_stage.id)
      expect(history.reload.pipeline_stage_id).to eq(source_stage.id)
      expect_unrelated_untouched
    end

    it 'rejects multiple completed journeys when no active card disambiguates them' do
      conversation = build_conversation
      first = build_card(conversation, completed_at: 2.days.ago)
      second = build_card(conversation, completed_at: 1.day.ago)

      move(conversation.id)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(first.reload.pipeline_stage_id).to eq(source_stage.id)
      expect(second.reload.pipeline_stage_id).to eq(source_stage.id)
    end

    it 'still allows selecting an exact historical card UUID' do
      conversation = build_conversation
      first = build_card(conversation, completed_at: 2.days.ago)
      second = build_card(conversation, completed_at: 1.day.ago)

      move(second.id)

      expect(response).to have_http_status(:ok)
      expect(first.reload.pipeline_stage_id).to eq(source_stage.id)
      expect(second.reload.pipeline_stage_id).to eq(target_stage.id)
    end
  end

  describe 'card-only endpoints' do
    it 'keeps update scoped to the card UUID even if it also names a different conversation' do
      conversation = build_conversation
      card = build_card(build_conversation, id: conversation.id)

      patch "/api/v1/pipelines/#{pipeline.id}/pipeline_items/#{card.id}",
            params: { pipeline_stage_id: target_stage.id }, as: :json

      expect(response).to have_http_status(:ok)
      expect(card.reload.pipeline_stage_id).to eq(target_stage.id)
      expect_unrelated_untouched
    end

    it 'does not introduce a public-number alias for update' do
      patch "/api/v1/pipelines/#{pipeline.id}/pipeline_items/2",
            params: { pipeline_stage_id: target_stage.id }, as: :json

      expect(response).to have_http_status(:not_found)
      expect_unrelated_untouched
    end
  end

  describe 'conversation create and relocate endpoints' do
    [:create_card, :relocate].each do |write|
      it "#{write} resolves the UUID before considering any numeric namespace" do
        conversation = build_conversation(id: '2a000000-0000-4000-8000-000000000003')

        send(write, conversation.id)

        expect(response).to have_http_status(:success)
        expect(conversation.pipeline_items.find_by(pipeline: pipeline).pipeline_stage_id).to eq(target_stage.id)
        expect(response.parsed_body.dig('data', 'conversation_id')).to eq(conversation.id)
        expect_unrelated_untouched
      end

      it "#{write} accepts a complete public number" do
        conversation = build_conversation(display_id: 21)

        send(write, '21')

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('data', 'conversation_id')).to eq(conversation.id)
        expect(response.parsed_body.dig('data', 'conversation_display_id')).to eq(21)
        expect_unrelated_untouched
      end

      %w[2garbage 2a000000-0000-4000-8000-000000009999 2147483648].each do |identifier|
        it "#{write} rejects #{identifier.inspect} without changing another conversation" do
          expect { send(write, identifier) }.not_to change(PipelineItem, :count)

          expect(response).not_to have_http_status(:success)
          expect_unrelated_untouched
        end
      end
    end

    it 'does not accept a card UUID as a conversation identifier' do
      relocate(unrelated_card.id)

      expect(response).not_to have_http_status(:success)
      expect_unrelated_untouched
    end

    it 'accepts the greatest public number supported by the database column' do
      conversation = build_conversation(display_id: 2_147_483_647)

      create_card('2147483647')

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig('data', 'conversation_id')).to eq(conversation.id)
      expect_unrelated_untouched
    end

    [2.5, true, ['2'], { number: 2 }, nil, '', ' 2 ', '+2'].each do |identifier|
      it "rejects an untyped conversation identifier #{identifier.inspect}" do
        expect { create_card(identifier) }.not_to change(PipelineItem, :count)

        expect(response).not_to have_http_status(:success)
        expect_unrelated_untouched
      end
    end

    it 'keeps the explicit skip contract when the target stage is outside the pipeline' do
      other = Pipeline.create!(name: 'Other', pipeline_type: 'sales', created_by: user)
      other_stage = other.pipeline_stages.create!(name: 'Other target', position: 1)

      relocate(unrelated.id, stage: other_stage)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('data', 'moved')).to be(false)
      expect(response.parsed_body.dig('data', 'reason')).to eq('stage_not_found')
      expect_unrelated_untouched
    end

    it 'rejects ambiguous source placements across pipelines rather than choosing the first' do
      conversation = build_conversation
      cards = 2.times.map do |index|
        other = Pipeline.create!(name: "Source #{index}", pipeline_type: 'sales', created_by: user)
        stage = other.pipeline_stages.create!(name: 'Held', position: 1)
        PipelineItem.create!(pipeline: other, pipeline_stage: stage, conversation: conversation)
      end

      expect { relocate(conversation.id) }.not_to change(StageMovement, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      cards.each { |card| expect(card.reload.pipeline_id).not_to eq(pipeline.id) }
      expect_unrelated_untouched
    end
  end
end
