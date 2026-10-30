# frozen_string_literal: true

module Followups
  class Templates
    def self.fetch(template_id, version: nil)
      record = FollowupTemplate.find_by(id: template_id)
      return unless record&.approved?
      return if version && record.version.to_s != version.to_s

      { id: record.id, version: record.version, content: record.body }
    end
  end
end
