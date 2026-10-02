require 'rails_helper'

RSpec.describe Api::V1::Conversations::MessagesController, type: :controller do
  describe '#forward request limits' do
    before do
      controller.instance_variable_set(:@conversation, instance_double(Conversation))
    end

    it 'rejects more than ten unique source messages before queueing work' do
      allow(controller).to receive(:params).and_return(
        ActionController::Parameters.new(message_ids: (1..11).map(&:to_s), contact_ids: ['contact-1'])
      )

      expect(Messages::ForwardMessageJob).not_to receive(:set)
      expect(controller).to receive(:error_response).with(
        ApiErrorCodes::INVALID_PARAMETER,
        'Select between 1 and 10 messages',
        status: :unprocessable_entity
      )
      controller.send(:forward)
    end

    it 'rejects more than five unique recipient contacts before queueing work' do
      allow(controller).to receive(:params).and_return(
        ActionController::Parameters.new(message_ids: ['message-1'], contact_ids: (1..6).map(&:to_s))
      )

      expect(Messages::ForwardMessageJob).not_to receive(:set)
      expect(controller).to receive(:error_response).with(
        ApiErrorCodes::INVALID_PARAMETER,
        'Select between 1 and 5 contacts',
        status: :unprocessable_entity
      )
      controller.send(:forward)
    end

  end
end
