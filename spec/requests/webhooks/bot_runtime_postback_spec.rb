# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Bot Runtime postback handoff marker', type: :request do
  let(:conversation) { instance_double(Conversation, id: 'conversation-uuid', display_id: 3686, inbox: instance_double(Inbox)) }
  let(:agent_bot) { instance_double(AgentBot) }
  let(:creator) { instance_double(AgentBots::MessageCreator) }

  before do
    allow(BotRuntime::Config).to receive(:secret).and_return(nil)
    allow(Conversation).to receive(:find_by).with(display_id: '3686').and_return(conversation)
    allow_any_instance_of(Webhooks::BotRuntimeController).to receive(:find_active_agent_bot).and_return(agent_bot)
    allow(AgentBots::MessageCreator).to receive(:new).with(agent_bot).and_return(creator)
    allow(AgentBots::MediaUrlExtractor).to receive(:call).and_return(text: 'resposta final', media: [])
    allow(creator).to receive(:create_bot_reply).and_return(instance_double(Message, id: 'reply-uuid'))
  end

  context 'with a stable runtime delivery ID' do
    let(:messages) { double('messages') }
    let(:scoped_messages) { double('scoped messages') }
    let(:existing_reply) { nil }

    before do
      allow(conversation).to receive(:with_lock).and_yield
      allow(conversation).to receive(:messages).and_return(messages)
      allow(messages).to receive(:where).with(sender: agent_bot).and_return(scoped_messages)
      allow(scoped_messages).to receive(:where)
        .with("content_attributes ->> 'runtime_delivery_id' = ?", 'batch:part:0').and_return(scoped_messages)
      allow(scoped_messages).to receive(:first).and_return(existing_reply)
    end

    it 'persists the key with the reply under the conversation lock' do
      post '/webhooks/bot_runtime/postback/3686',
           params: { content: 'resposta final', runtime_delivery_id: 'batch:part:0' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(conversation).to have_received(:with_lock)
      expect(creator).to have_received(:create_bot_reply).with(
        'resposta final', conversation,
        hash_including(content_attributes: { runtime_delivery_id: 'batch:part:0' })
      )
    end

    context 'when a previous request committed but its acknowledgement was lost' do
      let(:existing_reply) { instance_double(Message, id: 'reply-uuid') }

      it 'acknowledges the existing reply without creating another message' do
        post '/webhooks/bot_runtime/postback/3686',
             params: { content: 'resposta final', runtime_delivery_id: 'batch:part:0' }, as: :json

        expect(response).to have_http_status(:ok)
        expect(creator).not_to have_received(:create_bot_reply)
      end
    end
  end

  it 'permite force somente quando o runtime envia boolean true' do
    post '/webhooks/bot_runtime/postback/3686', params: { content: 'resposta final', force: true }, as: :json

    expect(response).to have_http_status(:ok)
    expect(creator).to have_received(:create_bot_reply).with(
      'resposta final', conversation, hash_including(force: true, content_type: 'text', media: [])
    )
  end

  it 'mantém respostas comuns sob validação de elegibilidade' do
    post '/webhooks/bot_runtime/postback/3686', params: { content: 'resposta final' }, as: :json

    expect(response).to have_http_status(:ok)
    expect(creator).to have_received(:create_bot_reply).with(
      'resposta final', conversation, hash_including(force: false, content_type: 'text', media: [])
    )
  end

  it 'não aceita string true como sinal de bypass' do
    post '/webhooks/bot_runtime/postback/3686', params: { content: 'resposta final', force: 'true' }, as: :json

    expect(response).to have_http_status(:ok)
    expect(creator).to have_received(:create_bot_reply).with(
      'resposta final', conversation, hash_including(force: false)
    )
  end
end
