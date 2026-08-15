# frozen_string_literal: true

require_relative "context_budget"

# EmergencyCompression — picoclaw's reactive LLM-call recovery (pkg/agent/
# pipeline_llm.go:280-450). Sits immediately around the terminal completion:
#
# - transient errors (timeout / network / rate-limit / overloaded / 5xx) →
#   retry with linear backoff ((retry+1) x backoff_secs), up to max_retries
# - context-window errors → force-compress (drop oldest ~50% of turns, note in
#   the summary sidecar) + trim to fit, then retry within the same budget
# - anything else (or budget exhausted) → raise
#
# Config (agents.defaults): max_llm_retries 2, llm_retry_backoff_secs 2.
class EmergencyCompression
  CONTEXT_PATTERNS = [
    "context_length_exceeded", "context window", "context_window",
    "maximum context length", "token limit", "too many tokens",
    "max_tokens", "invalidparameter", "prompt is too long", "request too large",
  ].freeze
  TRANSIENT_PATTERNS = [
    "deadline exceeded", "client.timeout", "timed out", "timeout exceeded",
    "connection reset", "connection refused", "broken pipe",
    "rate limit", "overloaded", "server error", "bad gateway",
    "service unavailable", "gateway timeout",
  ].freeze

  def initialize(app, max_retries: 2, backoff_secs: 2, summary_path: nil,
                 tool_defs: [], max_tokens: nil, context_window: nil)
    @app = app
    @max_retries = max_retries
    @backoff_secs = backoff_secs
    @summary_path = summary_path
    @tool_defs = tool_defs
    @max_tokens = ContextBudget.resolve_max_tokens(max_tokens)
    @context_window = ContextBudget.resolve_window(context_window, @max_tokens)
  end

  def call(env)
    retries = 0
    begin
      @app.call(env)
    rescue StandardError => e
      message = e.message.to_s.downcase

      if retries < @max_retries && transient?(message)
        retries += 1
        sleep(retries * @backoff_secs)
        retry
      end

      if retries < @max_retries && context_error?(message)
        retries += 1
        warn "context window exceeded — compressing history and retrying"
        ContextBudget.force_compress(env[:messages], summary_path: @summary_path)
        ContextBudget.trim_to_fit(env[:messages], tool_defs: @tool_defs, max_tokens: @max_tokens,
                                                 context_window: @context_window)
        retry
      end

      raise
    end
  end

  private

  def transient?(message)
    TRANSIENT_PATTERNS.any? { |p| message.include?(p) }
  end

  def context_error?(message)
    CONTEXT_PATTERNS.any? { |p| message.include?(p) }
  end
end
