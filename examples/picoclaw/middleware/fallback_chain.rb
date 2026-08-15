# frozen_string_literal: true

require "json"
require "fileutils"

# FallbackChain — picoclaw's candidate failover + rate limiting (pkg/providers/
# fallback.go, cooldown.go, ratelimiter.go, error_classifier.go).
#
# Sits immediately around the terminal LLM call (inside EmergencyCompression).
# Candidates = primary model + agents.defaults.model_fallbacks. Per attempt:
# skip in-cooldown candidates → RPM token bucket (non-last candidates with a
# saturated bucket are skipped; the LAST candidate blocks until refill) → the
# chosen model is written to env[:metadata][:llm_model] (the terminal proc
# reads it) → call. Errors are classified: auth/format abort the chain
# immediately; billing gets the 5h→24h cooldown ladder; other retriable
# failures get the 1m→5m→25m→1h ladder; all failed → FallbackExhaustedError.
#
# State (cooldown counters, buckets) persists in state/fallback_chain.json —
# this port runs one turn per process, so in-memory state would not survive.
class FallbackChain
  STANDARD_COOLDOWNS_MS = [60_000, 300_000, 1_500_000, 3_600_000].freeze # 1m 5m 25m 1h
  BILLING_BASE_MS = 5 * 60 * 60 * 1000  # 5h
  BILLING_MAX_MS = 24 * 60 * 60 * 1000  # 24h
  FAILURE_WINDOW_MS = 24 * 60 * 60 * 1000

  class AllFailed < StandardError; end

  def initialize(app, candidates:, state_path:, now: nil)
    @app = app
    # [{ "name" => model, "rpm" => n|nil }] — primary first.
    @candidates = candidates
    @state_path = state_path
    @now = now || -> { Time.now }
  end

  def call(env)
    state = load_state
    attempts = []

    @candidates.each_with_index do |candidate, index|
      key = candidate["name"].to_s
      if cooldown_remaining_ms(state, key) > 0
        attempts << "#{key}: skipped (cooldown)"
        next
      end

      unless acquire_bucket(state, key, candidate["rpm"], block: index == @candidates.size - 1)
        attempts << "#{key}: rate limited"
        next
      end

      env[:metadata][:llm_model] = key
      begin
        result = @app.call(env)
        mark_success(state, key)
        save_state(state)
        return result
      rescue StandardError => e
        reason = self.class.classify(e)
        attempts << "#{key}: #{e.message}"
        if %i[auth format].include?(reason)
          save_state(state)
          raise
        end
        mark_failure(state, key, reason)
        save_state(state)
      end
    end

    raise AllFailed, "all fallback candidates failed: #{attempts.join("; ")}"
  end

  # error_classifier port (message-based; the port's errors come from
  # open_router_enhanced exceptions carrying status codes/bodies).
  def self.classify(error)
    msg = error.message.to_s.downcase
    return :billing if msg.include?("402") || msg.include?("insufficient") || msg.include?("billing") || msg.include?("credit")
    return :auth if msg.include?("401") || msg.include?("403") || msg.include?("invalid api key") || msg.include?("unauthorized")
    return :format if msg.include?("400") || msg.include?("invalid request") || msg.include?("malformed")
    return :rate_limit if msg.include?("429") || msg.include?("rate limit")
    return :overloaded if msg.include?("overloaded") || msg.include?("503") || msg.include?("502")
    return :timeout if msg.include?("timeout") || msg.include?("timed out") || msg.include?("deadline")
    return :network if msg.include?("connection") || msg.include?("broken pipe") || msg.include?("eof")

    :unknown # retriable by default (upstream: unknown errors advance the chain)
  end

  private

  def now_ms = (@now.call.to_f * 1000).to_i

  def load_state
    return {} unless File.exist?(@state_path)

    JSON.parse(File.read(@state_path))
  rescue JSON::ParserError
    {}
  end

  def save_state(state)
    FileUtils.mkdir_p(File.dirname(@state_path))
    tmp = "#{@state_path}.tmp"
    File.write(tmp, JSON.pretty_generate(state))
    File.rename(tmp, @state_path)
  end

  def entry(state, key)
    state[key] ||= {}
  end

  # 24h failure window: counters reset when the last failure is older.
  def fresh_entry(state, key)
    e = entry(state, key)
    if e["last_failure_at"] && now_ms - e["last_failure_at"] > FAILURE_WINDOW_MS
      state[key] = e = {}
    end
    e
  end

  def cooldown_remaining_ms(state, key)
    e = fresh_entry(state, key)
    until_ms = e["cooldown_until"].to_i
    [until_ms - now_ms, 0].max
  end

  def mark_success(state, key)
    state.delete(key)
  end

  def mark_failure(state, key, reason)
    e = fresh_entry(state, key)
    e["last_failure_at"] = now_ms
    if reason == :billing
      n = e["billing_errors"].to_i + 1
      e["billing_errors"] = n
      cooldown = [BILLING_BASE_MS * (2**[n - 1, 10].min), BILLING_MAX_MS].min
    else
      n = e["errors"].to_i + 1
      e["errors"] = n
      cooldown = STANDARD_COOLDOWNS_MS[[[n, 1].max - 1, 3].min]
    end
    e["cooldown_until"] = now_ms + cooldown
  end

  # Token bucket: capacity = refill rate = rpm per minute.
  def acquire_bucket(state, key, rpm, block:)
    rpm = rpm.to_i
    return true if rpm <= 0

    e = entry(state, key)
    bucket = (e["bucket"] ||= { "tokens" => rpm, "updated_ms" => now_ms })
    elapsed_min = (now_ms - bucket["updated_ms"].to_i) / 60_000.0
    bucket["tokens"] = [bucket["tokens"].to_f + elapsed_min * rpm, rpm].min
    bucket["updated_ms"] = now_ms

    if bucket["tokens"] >= 1
      bucket["tokens"] -= 1
      return true
    end
    return false unless block

    # Last candidate: block until the bucket refills.
    wait = (1.0 - bucket["tokens"]) / rpm * 60.0
    sleep(wait)
    bucket["tokens"] = 0
    true
  end
end
