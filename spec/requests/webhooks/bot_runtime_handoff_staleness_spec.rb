# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Bot Runtime handoff staleness', type: :request do
  let(:contact) { Contact.create!(name: 'Handoff test') }
  let(:inbox) { Inbox.create!(name: 'Handoff test', channel: Channel::Api.create!) }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :pending) }
  let(:source) { Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming, content: 'request') }
  let(:controller) { Webhooks::BotRuntimeController.new }

  before do
    allow(BotRuntime::Config).to receive(:enabled?).and_return(false)
    source.update!(created_at: 1.minute.ago)
    controller.params = ActionController::Parameters.new(source_message_ids: [source.id])
  end

  def stale?
    controller.send(:stale_handoff?, conversation)
  end

  it 'allows the final handoff when nothing newer exists' do
    expect(stale?).to be(false)
  end

  it 'blocks a handoff after the conversation is resolved' do
    conversation.update!(status: :resolved)
    expect(stale?).to be(true)
  end

  it 'blocks a handoff after another customer message' do
    Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming, content: 'new message')
    expect(stale?).to be(true)
  end

  it 'treats a different incoming message in the same timestamp second as potentially newer' do
    other = Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming, content: 'same second')
    other.update!(created_at: source.created_at)
    expect(stale?).to be(true)
  end

  it 'blocks a handoff after a human outgoing message' do
    Message.create!(inbox: inbox, conversation: conversation, message_type: :outgoing, content: 'human reply')
    expect(stale?).to be(true)
  end

  it 'returns a conflict for a stale handoff through the real postback endpoint' do
    bot = AgentBot.create!(name: 'Handoff test')
    allow(BotRuntime::Config).to receive(:secret).and_return(nil)
    AgentBotInbox.create!(inbox: inbox, agent_bot: bot)
    Message.create!(inbox: inbox, conversation: conversation, message_type: :incoming, content: 'new message')
    before_count = Message.count

    post "/webhooks/bot_runtime/postback/#{conversation.display_id}",
         params: { content: 'handoff', force: true, runtime_delivery_id: 'batch:0',
                   source_message_ids: [source.id], source_agent_bot_id: bot.id }, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('ERR_STALE_TURN')
    expect(Message.count).to eq(before_count)
  end

  it 'rejects a handoff after the assigned agent changes' do
    bot = AgentBot.create!(name: 'Current bot')
    allow(BotRuntime::Config).to receive(:secret).and_return(nil)
    AgentBotInbox.create!(inbox: inbox, agent_bot: bot)
    before_count = Message.count

    post "/webhooks/bot_runtime/postback/#{conversation.display_id}",
         params: { content: 'handoff', force: true, runtime_delivery_id: 'batch:0',
                   source_message_ids: [source.id], source_agent_bot_id: SecureRandom.uuid }, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('ERR_STALE_TURN')
    expect(Message.count).to eq(before_count)
  end

  it 'rejects an unknown or invalid source message' do
    controller.params = ActionController::Parameters.new(source_message_ids: [SecureRandom.uuid])
    expect(stale?).to be(true)
    controller.params = ActionController::Parameters.new(source_message_ids: ['bad-id'])
    expect(stale?).to be(true)
  end
end
