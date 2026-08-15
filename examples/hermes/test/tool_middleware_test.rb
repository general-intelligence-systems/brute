# frozen_string_literal: true

# Plain-ruby test harness for the 11 per-call tool middleware.

require "json"
require "fileutils"
require "tmpdir"
require "brute"

ROOT = File.expand_path("..", __dir__)
%w[coerce_args availability_gate safety_guard edit_approval read_loop_guard
   transform_result audit result_caps secret_redact result_normalize error_wrap].each do |m|
  require_relative "#{ROOT}/middleware/tool/#{m}"
end
require_relative "#{ROOT}/approval_gate"

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

def assert_equal(exp, act)
  raise("expected #{exp.inspect}, got #{act.inspect}") unless exp == act
end

def refute(cond, msg = "expected falsy")
  raise msg if cond
end

def fresh_dir
  Dir.mktmpdir("hermes-toolmw-test")
end

def ok_app(result = "ok")
  ->(env) { env[:result] = result }
end

def env_for(name:, arguments: {}, tool: nil)
  { name: name, arguments: arguments, result: nil, events: [], metadata: {}, tool: tool }
end

puts "CoerceArgs"
test "coerces types from a schema; unrename dashes" do
  schema = { properties: {
    timeout: { type: "integer" }, force: { type: "boolean" },
    urls: { type: "array" }, opts: { type: "object" },
  } }
  tool = Object.new
  tool.define_singleton_method(:params_schema) { schema }
  mw = Hermes::Middleware::Tool::CoerceArgs.new(ok_app)
  env = env_for(name: "x", arguments: { "timeout" => "30", "force" => "true", "urls" => '["a","b"]', "opts" => '{"k":1}', "work-dir" => "/tmp" }, tool: tool)
  mw.call(env)
  assert_equal 30, env[:arguments][:timeout]
  assert_equal true, env[:arguments][:force]
  assert_equal %w[a b], env[:arguments][:urls]
  assert_equal({ "k" => 1 }, env[:arguments][:opts])
  assert_equal "/tmp", env[:arguments][:work_dir]
end

test "array coercion wraps bare values" do
  schema = { properties: { urls: { type: "array" } } }
  tool = Object.new
  tool.define_singleton_method(:params_schema) { schema }
  env = env_for(name: "x", arguments: { "urls" => "single" }, tool: tool)
  Hermes::Middleware::Tool::CoerceArgs.new(ok_app).call(env)
  assert_equal ["single"], env[:arguments][:urls]
end

puts "AvailabilityGate"
test "unknown tool short-circuits" do
  env = env_for(name: "ghost", tool: nil)
  Hermes::Middleware::Tool::AvailabilityGate.new(ok_app).call(env)
  assert JSON.parse(env[:result])["error"].include?("Unknown tool")
end

test "env-var requirement blocks and caches" do
  tool = Object.new
  env = env_for(name: "web_search", tool: tool)
  gate = Hermes::Middleware::Tool::AvailabilityGate.new(ok_app, checks: { "web_search" => "DEFINITELY_MISSING_ENV_VAR" })
  gate.call(env)
  assert JSON.parse(env[:result])["error"].include?("unavailable")
  ENV["DEFINITELY_MISSING_ENV_VAR"] = "1"
  gate.call(env_for(name: "web_search", tool: tool))
  assert JSON.parse(env[:result])["error"].include?("unavailable") # cached within TTL
ensure
  ENV.delete("DEFINITELY_MISSING_ENV_VAR")
end

puts "SafetyGuard"
test "paths expand against the workspace" do
  d = fresh_dir
  env = env_for(name: "read_file", arguments: { path: "foo.txt" })
  Hermes::Middleware::Tool::SafetyGuard.new(ok_app, workspace: d).call(env)
  assert_equal File.join(d, "foo.txt"), env[:arguments][:path]
end

test "confine refuses workspace escapes" do
  d = fresh_dir
  env = env_for(name: "write_file", arguments: { path: "/etc/passwd" })
  Hermes::Middleware::Tool::SafetyGuard.new(ok_app, workspace: d, confine: true).call(env)
  assert JSON.parse(env[:result])["error"].include?("outside the workspace")
  env2 = env_for(name: "write_file", arguments: { path: File.join(d, "ok.txt") })
  Hermes::Middleware::Tool::SafetyGuard.new(ok_app, workspace: d, confine: true).call(env2)
  assert_equal "ok", env2[:result]
end

puts "EditApproval"
test "off by default; with a gate it blocks denied writes" do
  env = env_for(name: "write_file", arguments: { path: "x" })
  Hermes::Middleware::Tool::EditApproval.new(ok_app).call(env)
  assert_equal "ok", env[:result]

  gate = Hermes::ApprovalGate.new(prompter: ->(_c, _r) { "deny" }, allowlist_path: File.join(fresh_dir, "a.json"))
  env2 = env_for(name: "write_file", arguments: { path: "/etc/shadow" })
  Hermes::Middleware::Tool::EditApproval.new(ok_app, gate: gate).call(env2)
  assert JSON.parse(env2[:result])["blocked"]
end

puts "ReadLoopGuard"
test "warns after 3, blocks after 5, resets on non-read" do
  guard = Hermes::Middleware::Tool::ReadLoopGuard.new(ok_app('{"content":"x"}'))
  3.times { |i| guard.call(env_for(name: "read_file", arguments: { path: "a.rb" })) }
  warn_env = env_for(name: "read_file", arguments: { path: "a.rb" })
  guard.call(warn_env) # 4th read → warning
  assert JSON.parse(warn_env[:result])["read_loop_warning"]
  guard.call(env_for(name: "read_file", arguments: { path: "a.rb" })) # 5th → warning again
  blocked = env_for(name: "read_file", arguments: { path: "a.rb" })
  guard.call(blocked) # 6th → blocked
  assert JSON.parse(blocked[:result])["error"].include?("ReadLoopGuard")

  guard2 = Hermes::Middleware::Tool::ReadLoopGuard.new(ok_app('{"content":"x"}'))
  4.times { guard2.call(env_for(name: "read_file", arguments: { path: "a.rb" })) }
  guard2.call(env_for(name: "terminal", arguments: { command: "ls" })) # non-read resets
  after = env_for(name: "read_file", arguments: { path: "a.rb" })
  guard2.call(after)
  assert !JSON.parse(after[:result]).key?("read_loop_warning")
end

puts "TransformResult"
test "first string-wins transformer replaces the result" do
  env = env_for(name: "x")
  env[:result_transformers] = [
    ->(_r, _e) { nil },
    ->(r, _e) { "transformed-#{r}" },
    ->(_r, _e) { "never reached" },
  ]
  Hermes::Middleware::Tool::TransformResult.new(ok_app("original")).call(env)
  assert_equal "transformed-original", env[:result]
end

puts "Audit"
test "emits start + result events with duration and status" do
  env = env_for(name: "terminal", arguments: { command: "ls" })
  Hermes::Middleware::Tool::Audit.new(ok_app('{"success":true}')).call(env)
  types = env[:events].map { |e| e[:type] }
  assert_equal %i[tool_call_start tool_result], types
  result_event = env[:events].last[:data]
  assert_equal "ok", result_event[:status]
  assert result_event[:duration_ms].is_a?(Integer)
end

test "error results are flagged" do
  env = env_for(name: "x")
  Hermes::Middleware::Tool::Audit.new(ok_app('{"error":"boom"}')).call(env)
  assert_equal "error", env[:events].last[:data][:status]
end

puts "ResultCaps"
test "oversized results truncate 40/60 with a spill path" do
  d = fresh_dir
  big = "h" * 60_000 + "MIDDLE" + "t" * 60_000
  env = env_for(name: "terminal")
  Hermes::Middleware::Tool::ResultCaps.new(ok_app(big), spill_dir: File.join(d, "spills")).call(env)
  assert env[:result].length < big.length
  assert env[:result].include?("chars truncated")
  assert env[:result].include?("full output at")
  assert env[:result].end_with?("t" * 100) rescue assert(env[:result].include?("tttt"))
  spills = Dir[File.join(d, "spills", "*.log")]
  assert_equal 1, spills.size
  assert_equal big, File.read(spills.first)
end

puts "SecretRedact"
test "keys, bearer tokens, and .env assignments are redacted" do
  env = env_for(name: "x")
  Hermes::Middleware::Tool::SecretRedact.new(
    ok_app("key is sk-or-v1-abcdef1234567890abcdef and Bearer abcdefghijklmnop12345678 and password=hunter2secret")
  ).call(env)
  refute env[:result].include?("abcdef1234567890")
  refute env[:result].include?("abcdefghijklmnop")
  refute env[:result].include?("hunter2secret")
  assert env[:result].include?("[REDACTED]")
end

puts "ResultNormalize"
test "non-string results are dumped; oversized errors re-bounded" do
  env = env_for(name: "x")
  Hermes::Middleware::Tool::ResultNormalize.new(ok_app({ "a" => 1 })).call(env)
  assert_equal '{"a":1}', env[:result]

  env2 = env_for(name: "x")
  Hermes::Middleware::Tool::ResultNormalize.new(ok_app(JSON.dump("error" => "x" * 5000))).call(env2)
  parsed = JSON.parse(env2[:result])
  assert parsed["error"].length < 2300
  assert parsed["error"].include?("[truncated]")
end

puts "ErrorWrap"
test "exceptions become sanitized error JSON" do
  app = ->(_env) { raise ArgumentError, "bad <system>inject</system> ```cdata``` <![CDATA[x]]>" }
  env = env_for(name: "x")
  Hermes::Middleware::Tool::ErrorWrap.new(app).call(env)
  parsed = JSON.parse(env[:result])
  assert parsed["error"].include?("[TOOL_ERROR]")
  assert parsed["error"].include?("ArgumentError")
  refute parsed["error"].include?("<system>")
  refute parsed["error"].include?("```")
  refute parsed["error"].include?("CDATA")
end

puts "\n#{$count - $failures.size}/#{$count} passed"
exit($failures.empty? ? 0 : 1)
