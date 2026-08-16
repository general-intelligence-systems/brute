# frozen_string_literal: true

# Plain-ruby test harness for ErrorRecovery — every reason, every branch.

require "json"
require "brute"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/middleware/error_recovery"
require_relative "#{ROOT}/compactor"

$failures = []
$count = 0

def test(name)
  $count += 1
  yield
  puts "  ok  #{name}"
rescue StandardError => e
  $failures << name
  puts "FAIL  #{name}: #{e.message}"
end

def assert(cond, msg = "expected truthy")
  raise msg unless cond
end

def assert_eq(exp, act)
  raise("expected #{exp.inspect}, got #{act.inspect}") unless exp == act
end

def refute(cond, msg = "expected falsy")
  raise msg if cond
end

class FakeError < StandardError
  attr_reader :status
  def initialize(msg, status = nil)
    @status = status
    super(msg)
  end
end

def base_env
  env = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  env[:messages].user("hi")
  env
end

def mw(errors_or_ok, **opts)
  inner = ->(env) {
    outcome = errors_or_ok.is_a?(Array) ? (errors_or_ok.shift || errors_or_ok[-1]) : errors_or_ok
    raise outcome if outcome.is_a?(Exception)

    env[:messages] << Brute::Message.new(role: :assistant, content: outcome.is_a?(String) ? outcome : "ok")
  }
  Hermes::Middleware::ErrorRecovery.new(inner, sleep_proc: ->(_s) {}, **opts)
end

puts "classification"
test "every reason classified correctly" do
  mw_inst = Hermes::Middleware::ErrorRecovery.new(->(_e) {})
  assert_eq :ssl_cert_verification, mw_inst.classify(OpenSSL::SSL::SSLError.new("certificate verify failed"))
  assert_eq :timeout, mw_inst.classify(Timeout::Error.new)
  assert_eq :auth, mw_inst.classify(FakeError.new("unauthorized", 401))
  assert_eq :billing, mw_inst.classify(FakeError.new("insufficient credits", 402))
  assert_eq :billing, mw_inst.classify(FakeError.new("quota exceeded"))
  assert_eq :rate_limit, mw_inst.classify(FakeError.new("slow down", 429))
  assert_eq :upstream_rate_limit, mw_inst.classify(FakeError.new("upstream model rate limited", 429))
  assert_eq :server_error, mw_inst.classify(FakeError.new("boom", 500))
  assert_eq :overloaded, mw_inst.classify(FakeError.new("busy", 503))
  assert_eq :model_not_found, mw_inst.classify(FakeError.new("no such model", 404))
  assert_eq :payload_too_large, mw_inst.classify(FakeError.new("too big", 413))
  assert_eq :context_overflow, mw_inst.classify(FakeError.new("maximum context length exceeded"))
  assert_eq :content_policy_blocked, mw_inst.classify(FakeError.new("blocked by content policy"))
  assert_eq :format_error, mw_inst.classify(FakeError.new("bad request", 400))
  assert_eq :unknown, mw_inst.classify(FakeError.new("???"))
end

puts "retryable reasons (backoff)"
test "429 retries with backoff then succeeds" do
  calls = 0
  inner = ->(env) { calls += 1; raise FakeError.new("429", 429) if calls < 3; env[:messages] << Brute::Message.new(role: :assistant, content: "recovered") }
  env = base_env
  Hermes::Middleware::ErrorRecovery.new(inner, sleep_proc: ->(_s) {}).call(env)
  assert_eq 3, calls
  assert env[:messages].last.content == "recovered"
end

test "exhausted retries end terminal with an assistant explanation, never a raise" do
  env = base_env
  mw(FakeError.new("boom", 500), max_retries: 2).call(env)
  assert env[:should_exit]
  assert env[:messages].last.content.include?("unavailable")
end

puts "once-only and terminal reasons"
test "auth gets exactly one retry, then permanent" do
  calls = 0
  inner = ->(_env) { calls += 1; raise FakeError.new("401", 401) }
  env = base_env
  Hermes::Middleware::ErrorRecovery.new(inner, sleep_proc: ->(_s) {}).call(env)
  assert_eq 2, calls
  assert env[:should_exit][:classified] == :auth_permanent
  assert env[:messages].last.content.include?("Authentication failed")
end

test "billing fails immediately with guidance" do
  calls = 0
  inner = ->(_env) { calls += 1; raise FakeError.new("insufficient credits", 402) }
  env = base_env
  Hermes::Middleware::ErrorRecovery.new(inner, sleep_proc: ->(_s) {}).call(env)
  assert_eq 1, calls
  assert env[:messages].last.content.include?("billing/quota")
end

test "ssl fails fast (deterministic)" do
  calls = 0
  inner = ->(_env) { calls += 1; raise OpenSSL::SSL::SSLError.new("certificate verify failed") }
  env = base_env
  Hermes::Middleware::ErrorRecovery.new(inner, sleep_proc: ->(_s) {}).call(env)
  assert_eq 1, calls
  assert env[:messages].last.content.include?("TLS")
end

puts "context overflow → compact → retry"
test "413 compacts and retries" do
  calls = 0
  inner = ->(env) {
    calls += 1
    if calls == 1
      12.times { |i| env[:messages] << Brute::Message.new(role: :user, content: "q#{i} #{'x' * 200}") << Brute::Message.new(role: :assistant, content: "a#{i}") }
      raise FakeError.new("too big", 413)
    end
    env[:messages] << Brute::Message.new(role: :assistant, content: "recovered")
  }
  compactor = Hermes::Compactor.new(context_length: 1_000, summarize: ->(_p) { "SUMMARY" })
  env = base_env
  Hermes::Middleware::ErrorRecovery.new(inner, compactor: compactor, sleep_proc: ->(_s) {}).call(env)
  assert_eq 2, calls
  assert env[:invalidate_system_prompt]
  assert env[:events].any? { |e| e[:type] == :compaction }
  assert env[:messages].any? { |m| m.content.to_s.include?("CONTEXT COMPACTION") }
end

puts "fallback model"
test "model_not_found switches to fallback once and retries" do
  calls = 0
  inner = ->(env) {
    calls += 1
    raise FakeError.new("404", 404) unless env[:model]
    env[:messages] << Brute::Message.new(role: :assistant, content: "ok on fallback")
  }
  env = base_env
  Hermes::Middleware::ErrorRecovery.new(inner, fallback_model: "openrouter/auto", sleep_proc: ->(_s) {}).call(env)
  assert env[:_fallback_used]
  assert_eq "openrouter/auto", env[:model]
  assert env[:messages].last.content == "ok on fallback"
end

test "no fallback configured → terminal" do
  env = base_env
  mw(FakeError.new("404", 404)).call(env)
  assert env[:messages].last.content.include?("no fallback")
end

puts "empty-response recovery"
test "empty after tool results: stamped nudge, internal retry, ephemeral marked" do
  calls = 0
  inner = ->(env) {
    calls += 1
    content = calls == 1 ? "" : "real answer"
    env[:messages] << Brute::Message.new(role: :assistant, content: content)
  }
  env = base_env
  env[:messages] << Brute::Message.new(role: :tool, content: "tool output", tool_call_id: "t1")
  Hermes::Middleware::ErrorRecovery.new(inner, sleep_proc: ->(_s) {}).call(env)
  assert_eq 2, calls
  assert env[:messages].any? { |m| m.content == "(empty)" }
  assert env[:messages].any? { |m| m.content.to_s.include?("empty response") }
  assert env[:messages].last.content == "real answer"
  assert env[:ephemeral_messages].size == 2, "scaffolding stamped ephemeral for SessionStore"
end

test "repeated empties exhaust: scaffolding + owning pair rewound" do
  inner = ->(env) { env[:messages] << Brute::Message.new(role: :assistant, content: "") }
  env = base_env
  env[:messages] << Brute::Message.new(role: :assistant, content: "",
    tool_calls: [Brute::ToolCall.new(id: "t1", name: "terminal", arguments: {})])
  env[:messages] << Brute::Message.new(role: :tool, content: "tool output", tool_call_id: "t1")
  Hermes::Middleware::ErrorRecovery.new(inner, sleep_proc: ->(_s) {}).call(env)
  assert env[:should_exit][:reason] == "empty_response_exhausted"
  refute env[:messages].any? { |m| m.content == "(empty)" }
  assert env[:messages].last.content.include?("empty response repeatedly")
end

puts "\n#{$count - $failures.size}/#{$count} passed"
exit($failures.empty? ? 0 : 1)
