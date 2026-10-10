# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MessageFinder do
  describe '#perform pagination' do
    let(:conversation) { create(:conversation) }

    it 'does not skip messages sharing the cursor timestamp when loading older pages' do
      timestamp = Time.zone.parse('2026-10-10 12:00:00')
      messages = 22.times.map do |index|
        create(:message, conversation: conversation, created_at: timestamp, content: "same-second-#{index}")
      end
      oldest_first = messages.sort_by { |message| [message.created_at, message.id] }
      first_page = described_class.new(conversation, {}).perform
      previous_page = described_class.new(conversation, { before: first_page.first.id }).perform

      expect(first_page.map(&:id)).to eq(oldest_first.last(20).map(&:id))
      expect(previous_page.map(&:id)).to eq(oldest_first.first(2).map(&:id))
      expect((first_page + previous_page).map(&:id).uniq.length).to eq(22)
    end

    it 'does not skip messages sharing the cursor timestamp when loading newer pages' do
      timestamp = Time.zone.parse('2026-10-10 12:00:00')
      messages = 22.times.map do |index|
        create(:message, conversation: conversation, created_at: timestamp, content: "same-second-#{index}")
      end
      oldest_first = messages.sort_by { |message| [message.created_at, message.id] }
      newer_page = described_class.new(conversation, { after: oldest_first.first.id }).perform

      expect(newer_page.map(&:id)).to eq(oldest_first.drop(1).map(&:id))
    end
  end
end
