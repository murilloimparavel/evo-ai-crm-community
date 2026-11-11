# frozen_string_literal: true

require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../../config/environment'
require_relative '../../app/models/custom_attribute_definition'

RSpec.describe 'CustomAttributeDefinition enum mapping' do
  it 'defines datetime display type mapped to 8' do
    expect(CustomAttributeDefinition.attribute_display_types['datetime']).to eq(8)
  end
end
