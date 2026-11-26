# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PipelineItemSerializer do
  let(:user) do
    User.create!(email: "pipeline-serializer-#{SecureRandom.hex(6)}@example.com", name: 'Pipeline Serializer')
  end
  let(:pipeline) do
    Pipeline.create!(name: "pipeline-serializer-#{SecureRandom.hex(6)}", pipeline_type: 'sales', created_by: user)
  end
  let(:first_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Entrada', position: 1) }
  let(:second_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Qualificado', position: 2) }

  def create_item(stage: first_stage)
    contact = Contact.create!(name: 'Pipeline Serializer Contact')
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact, entered_at: 10.days.ago)
  end

  describe '.latest_stage_movement_times_for' do
    it 'returns only the latest movement timestamp for each item' do
      item = create_item
      another_item = create_item
      item.stage_movements.update_all(created_at: 4.days.ago, updated_at: 4.days.ago)
      latest_movement = StageMovement.create!(
        pipeline_item: item,
        from_stage: first_stage,
        to_stage: second_stage,
        movement_type: 'manual',
        created_at: 2.days.ago,
        updated_at: 2.days.ago
      )

      result = described_class.latest_stage_movement_times_for([item, another_item])

      expect(result[item.id]).to eq(latest_movement.created_at)
      expect(result[another_item.id]).to be_present
    end

    it 'uses one grouped database query for multiple items' do
      items = [create_item, create_item]
      movement_queries = 0
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_event, _start, _finish, _id, payload|
        movement_queries += 1 if payload[:sql].include?('stage_movements') && !payload[:cached]
      end

      described_class.latest_stage_movement_times_for(items)

      expect(movement_queries).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'does not query the database for an empty collection' do
      expect(StageMovement).not_to receive(:where)

      expect(described_class.latest_stage_movement_times_for([])).to eq({})
    end
  end

  describe '.serialize' do
    it 'uses the batched movement timestamp to calculate days in the current stage' do
      travel_to(Time.zone.local(2026, 1, 10, 12, 0, 0)) do
        item = create_item
        StageMovement.where(pipeline_item: item).update_all(created_at: 3.days.ago)
        movement_times = described_class.latest_stage_movement_times_for([item])
        expect(item).not_to receive(:days_in_current_stage)

        serialized = described_class.serialize(item, stage_movement_times: movement_times)

        expect(serialized[:days_in_current_stage]).to eq(3)
      end
    end
  end
end
