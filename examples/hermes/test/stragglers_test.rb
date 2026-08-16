# frozen_string_literal: true

# Plain-ruby test harness for the stragglers: ErrorLog, UsageAudit,
# EvolutionLog, Curator, MemoryProviders, ContextEngine.

require "json"
require "fileutils"
require "tmpdir"
require "brute"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/middleware/error_log"
require_relative "#{ROOT}/middleware/usage_audit"
require_relative "#{ROOT}/middleware/evolution_log"
require_relative "#{ROOT}/curator"
require_relative "#{ROOT}/middleware/curator"
require_relative "#{ROOT}/middleware/memory_providers"
require_relative "#{ROOT}/middleware/context_engine"
require_relative "#{ROOT}/skill_store"

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

def assert_eq(exp, act, msg = nil)
  raise(msg || "expected #{exp.inspect}, got #{act.inspect}") unless exp == act
end

def assert(cond, msg = "expected truthy")
  raise msg unless cond
end

def refute(cond, msg = "expected falsy")
  raise msg if cond
end

def fresh_dir
  Dir.mktmpdir("hermes-stragglers-test")
end

def base_env
  env = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  env[:messages].user("hi")
  env
end

puts "ErrorLog"
test "turn events → agent.log; errors → errors.log" do
  d = fresh_dir
  inner = ->(env) {
    env[:events] << { type: :tool_result, data: { name: "terminal", status: "error", error_message: "boom" } }
  }
  Hermes::Middleware::ErrorLog.new(inner, dir: d).call(base_env)
  agent_log = File.read(File.join(d, "agent.log"))
  errors_log = File.read(File.join(d, "errors.log"))
  assert agent_log.include?("turn start")
  assert agent_log.include?("turn end")
  assert errors_log.include?("boom")
end

test "a raising turn is logged and re-raised" do
  d = fresh_dir
  inner = ->(_env) { raise "explode" }
  begin
    Hermes::Middleware::ErrorLog.new(inner, dir: d).call(base_env)
    raise "should have raised"
  rescue RuntimeError
  end
  assert File.read(File.join(d, "errors.log")).include?("explode")
end

puts "UsageAudit"
test "appends one JSONL record per call with usage" do
  d = fresh_dir
  path = File.join(d, "usage.jsonl")
  inner = ->(env) { env[:usage] = { input: 10, output: 5, total: 15, source: :provider } }
  env = base_env
  env[:model] = "m1"
  Hermes::Middleware::UsageAudit.new(inner, path: path).call(env)
  rec = JSON.parse(File.read(path).lines.first)
  assert_eq 15, rec["total"]
  assert_eq "m1", rec["model"]
end

puts "EvolutionLog"
test "appends a trimmed record per completed turn" do
  d = fresh_dir
  path = File.join(d, "records.jsonl")
  inner = ->(env) {
    env[:messages] << Brute::Message.new(role: :assistant, content: "",
      tool_calls: [Brute::ToolCall.new(id: "t1", name: "terminal", arguments: {})])
    env[:messages] << Brute::Message.new(role: :tool, content: "output", tool_call_id: "t1")
    env[:messages] << Brute::Message.new(role: :assistant, content: "the answer")
  }
  env = base_env
  env[:review_memory] = true
  Hermes::Middleware::EvolutionLog.new(inner, path: path).call(env)
  rec = JSON.parse(File.read(path).lines.first)
  assert_eq 1, rec["tool_count"]
  assert_eq "terminal", rec["tools"].first["name"]
  assert_eq true, rec["review_fired"]["memory"]
  assert_eq "the answer", rec["reply_preview"]
end

puts "Curator"
def make_agent_skill(root, name, days_old: 0)
  dir = File.join(root, "custom", name)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "SKILL.md"), "---\ndescription: X does a thing.\n---\n\nBody.\n")
  past = Time.now - days_old * 86_400
  File.utime(past, past, File.join(dir, "SKILL.md"))
  dir
end

test "interval gate: disabled by default, due check by interval" do
  d = fresh_dir
  store = Hermes::SkillStore.new(dirs: [d])
  curator = Hermes::Curator.new(store, config_path: File.join(d, "curator.json"))
  refute curator.maybe_run, "disabled by default"
  File.write(File.join(d, "curator.json"), JSON.dump("enabled" => true, "interval_hours" => 24))
  curator = Hermes::Curator.new(store, config_path: File.join(d, "curator.json"))
  assert curator.maybe_run, "first run fires when enabled"
  refute curator.maybe_run, "second immediate run is gated by the interval"
end

test "transitions: active→stale→archived, only curator-managed, pinned exempt" do
  d = fresh_dir
  store = Hermes::SkillStore.new(dirs: [d])
  make_agent_skill(d, "old-skill", days_old: 20)
  make_agent_skill(d, "user-skill", days_old: 20)
  store.set_provenance("old-skill", created_by: "agent")
  store.mutate_usage("user-skill") { |r| r["pinned"] = true }

  config_path = File.join(d, "curator.json")
  File.write(config_path, JSON.dump("enabled" => true, "interval_hours" => 0,
    "stale_after_days" => 7, "archive_after_days" => 14, "backup" => false))
  curator = Hermes::Curator.new(store, config_path: config_path)
  curator.run

  assert_eq "archived", store.usage_record("old-skill")["state"]
  assert Dir.exist?(File.join(d, ".archive", "old-skill"))
  assert_eq "active", store.usage_record("user-skill")["state"], "pinned is exempt"
end

test "never deletes: archive moves the directory and is restorable" do
  d = fresh_dir
  store = Hermes::SkillStore.new(dirs: [d])
  make_agent_skill(d, "doomed")
  store.set_provenance("doomed", created_by: "agent")
  curator = Hermes::Curator.new(store, config_path: File.join(d, "curator.json"))
  curator.archive("doomed")
  assert Dir.exist?(File.join(d, ".archive", "doomed"))
  curator.restore("doomed")
  assert store.find("doomed"), "restored skill is discoverable again"
end

puts "MemoryProviders seam"
test "prefetch at turn start, sync_turn after, failures swallowed" do
  calls = []
  provider = Object.new
  provider.define_singleton_method(:prefetch) { |q| calls << [:prefetch, q] }
  provider.define_singleton_method(:sync_turn) { |msgs| calls << [:sync_turn, msgs.size] }
  bad = Object.new
  bad.define_singleton_method(:prefetch) { |*| raise "down" }
  bad.define_singleton_method(:sync_turn) { |*| raise "down" }

  inner = ->(env) { env[:messages] << Brute::Message.new(role: :assistant, content: "answer") }
  Hermes::Middleware::MemoryProviders.new(inner, providers: [provider, bad]).call(base_env)
  assert_eq [:prefetch, "hi"], calls.first
  assert_eq [:sync_turn, 1], calls.last
end

puts "ContextEngine seam"
test "engine sections land in env[:metadata][:context_sections]" do
  engine = ->(env) { ["## Extra Context\nfrom the engine"] }
  env = base_env
  Hermes::Middleware::ContextEngine.new(->(env) {}, engine: engine).call(env)
  assert_eq ["## Extra Context\nfrom the engine"], env[:metadata][:context_sections]

  broken = ->(_env) { raise "engine down" }
  env2 = base_env
  Hermes::Middleware::ContextEngine.new(->(env) {}, engine: broken).call(env2)
  assert env2[:metadata][:context_sections].nil?, "a broken engine must not block the prompt"
end

puts "\n#{$count - $failures.size}/#{$count} passed"
exit($failures.empty? ? 0 : 1)
