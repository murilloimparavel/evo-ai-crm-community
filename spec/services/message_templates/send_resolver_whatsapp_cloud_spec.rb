# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MessageTemplates::SendResolver do
  it 'does not resolve a pending WhatsApp Cloud template for sending' do
    channel = Channel::Whatsapp.new(provider: 'whatsapp_cloud', phone_number: "+1555#{SecureRandom.hex(3)}",
                                    provider_config: { 'waba_id' => "waba-#{SecureRandom.hex(3)}" })
    channel.save!(validate: false)
    template = MessageTemplate.create!(name: "pending_#{SecureRandom.hex(3)}", content: 'Hello', channel: channel,
                                       settings: { 'status' => 'PENDING' })

    expect(described_class.new(id: template.id, channel: channel).resolve).to be_nil
    expect(described_class.new(name: template.name, channel: channel).resolve).to be_nil
  end

  it 'does not fall back to a global generic template on a Cloud inbox' do
    channel = Channel::Whatsapp.new(provider: 'whatsapp_cloud', phone_number: "+1555#{SecureRandom.hex(3)}",
                                    provider_config: { 'waba_id' => "waba-#{SecureRandom.hex(3)}" })
    channel.save!(validate: false)
    template = MessageTemplate.create!(name: "generic_#{SecureRandom.hex(3)}", content: 'Hello', channel: nil)

    expect(described_class.new(id: template.id, channel: channel).resolve).to be_nil
    expect(described_class.new(name: template.name, channel: channel).resolve).to be_nil
  end
end
