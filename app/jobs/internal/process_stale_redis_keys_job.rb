# housekeeping
# remove stale redis presence keys

class Internal::ProcessStaleRedisKeysJob < ApplicationJob
  queue_as :low

  def perform(_legacy_argument = nil)
    removed_count = Internal::RemoveStaleRedisKeysService.new.perform
    Rails.logger.info "Successfully cleaned up stale Redis keys (removed #{removed_count} keys)"
  end
end
