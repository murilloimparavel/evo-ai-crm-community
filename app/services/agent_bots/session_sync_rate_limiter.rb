module AgentBots
  class SessionSyncRateLimiter
    REDIS_KEY = 'agent_bots:session_sync:token_bucket:v1'.freeze
    TOKEN_BUCKET_SCRIPT = <<~LUA.freeze
      local now = tonumber(ARGV[1])
      local refill_per_second = tonumber(ARGV[2])
      local capacity = tonumber(ARGV[3])
      local ttl = tonumber(ARGV[4])
      local state = redis.call('HMGET', KEYS[1], 'tokens', 'updated_at')
      local tokens = tonumber(state[1]) or capacity
      local updated_at = tonumber(state[2]) or now

      tokens = math.min(capacity, tokens + math.max(0, now - updated_at) * refill_per_second)
      local wait_seconds = 0
      if tokens >= 1 then
        tokens = tokens - 1
      else
        wait_seconds = (1 - tokens) / refill_per_second
      end

      redis.call('HSET', KEYS[1], 'tokens', tokens, 'updated_at', now)
      redis.call('EXPIRE', KEYS[1], ttl)
      return wait_seconds
    LUA

    def self.acquire_delay
      per_minute = Integer(ENV.fetch('SESSION_SYNC_RATE_LIMIT_PER_MINUTE', '30'), 10)
      per_minute = [[per_minute, 1].max, 600].min
      refill_per_second = per_minute / 60.0
      capacity = [per_minute, 5].min
      ttl = (capacity / refill_per_second).ceil + 60

      Sidekiq.redis do |redis|
        redis.eval(
          TOKEN_BUCKET_SCRIPT,
          keys: [REDIS_KEY],
          argv: [Time.now.to_f, refill_per_second, capacity, ttl]
        ).to_f
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error "[SessionSync] Invalid rate-limit configuration: #{e.class}"
      # Fail open on bad configuration so jobs do not reschedule forever.
      0.0
    end
  end
end
