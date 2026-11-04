require 'rails_helper'

RSpec.describe Notification::PushNotificationService do
  let(:user) { User.create!(name: 'Push operator', email: "delivery-#{SecureRandom.hex(5)}@example.test") }
  let(:contact) { Contact.create!(name: 'Synthetic contact') }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://example.test') }
  let(:inbox) { Inbox.create!(name: 'Reservas', channel: channel) }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:notification) { Notification.create!(user: user, notification_type: :conversation_assignment, primary_actor: conversation) }
  let!(:setting) { user.notification_settings.create!(selected_push_flags: ['push_conversation_assignment']) }
  let!(:subscription) do
    user.notification_subscriptions.create!(subscription_type: :browser_push, identifier: 'https://fcm.googleapis.com/fcm/send/synthetic',
                                            subscription_attributes: { endpoint: 'https://fcm.googleapis.com/fcm/send/synthetic',
                                                                       p256dh: 'key', auth: 'auth' })
  end

  before do
    key = WebPush.generate_key
    allow(VapidService).to receive_messages(public_key: key.public_key, private_key: key.private_key)
    allow(WebPush).to receive(:payload_send)
  end

  it 'sends the channel, recipient and current conversation route through WebPush' do
    described_class.new(notification: notification).perform
    expect(WebPush).to have_received(:payload_send) do |**options|
      payload = JSON.parse(options[:message])
      expect(payload['title']).to include("WebWidget · #{inbox.name}")
      expect(payload['user_id']).to eq(user.id)
      expect(payload['url']).to end_with("/conversations/#{conversation.display_id}")
      expect(payload['url']).not_to include('/app/conversations')
      expect(payload['body']).to eq('Abra o app para ver a mensagem.')
      expect(payload['tag']).to eq("notification-#{notification.id}")
    end
  end

  it 'enqueues push when an incoming message reaches its assigned operator' do
    setting.update!(selected_push_flags: ['push_assigned_conversation_new_message'])
    conversation.update!(assignee: user)
    message = Message.create!(conversation: conversation, inbox: inbox, sender: contact, message_type: :incoming,
                              content: 'Synthetic private message')
    Messages::NewMessageNotificationService.new(message: message).perform
    event = user.notifications.find_by!(secondary_actor: message, notification_type: :assigned_conversation_new_message)
    expect(Notification::PushNotificationJob).to have_been_enqueued.with(event)
    described_class.new(notification: event).perform
    expect(WebPush).to have_received(:payload_send) do |**options|
      expect(JSON.parse(options[:message])['title']).to include(inbox.name)
      expect(options[:message]).not_to include('Synthetic private message')
    end
  end

  it 'does not send when the event preference is disabled' do
    setting.update!(selected_push_flags: [])
    described_class.new(notification: notification).perform
    expect(WebPush).not_to have_received(:payload_send)
  end

  it 'preserves the subscription on VAPID authorization failure' do
    allow(WebPush).to receive(:payload_send).and_raise(WebPush::Unauthorized.new(instance_double(Net::HTTPUnauthorized, body: 'synthetic'),
                                                                                 'fcm.googleapis.com'))
    allow_any_instance_of(EvolutionExceptionTracker).to receive(:capture_exception) # rubocop:disable RSpec/AnyInstance
    described_class.new(notification: notification).perform
    expect(NotificationSubscription.exists?(subscription.id)).to be(true)
  end
end
