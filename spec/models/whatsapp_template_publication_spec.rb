# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WhatsappTemplatePublication, type: :model do
  it 'normalizes Meta approval states and records the sync time' do
    definition = WhatsappTemplateDefinition.create!(name: "hello_#{SecureRandom.hex(3)}", language: 'pt_BR',
                                                    category: 'UTILITY', content: 'Hello',
                                                    components: [{ 'type' => 'BODY', 'text' => 'Hello' }])
    publication = definition.publications.create!(waba_id: "waba-#{SecureRandom.hex(3)}")

    expect(publication.apply_meta_status!(raw_status: 'APPROVED', category: 'UTILITY')).to be(true)
    expect(publication.reload).to have_attributes(status: 'approved', raw_status: 'APPROVED', meta_category: 'UTILITY')
    expect(publication.synced_at).to be_present
  end

  it 'preserves unknown Meta statuses as an explicit unknown state' do
    definition = WhatsappTemplateDefinition.create!(name: "hello_#{SecureRandom.hex(3)}", language: 'pt_BR',
                                                    category: 'UTILITY', content: 'Hello',
                                                    components: [{ 'type' => 'BODY', 'text' => 'Hello' }])
    publication = definition.publications.create!(waba_id: "waba-#{SecureRandom.hex(3)}")

    expect(publication.apply_meta_status!(raw_status: 'SOME_NEW_STATE')).to be(true)
    expect(publication.reload).to have_attributes(status: 'unknown', raw_status: 'SOME_NEW_STATE')
  end
end
