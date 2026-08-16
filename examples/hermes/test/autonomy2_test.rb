# frozen_string_literal: true

# Plain-ruby test harness for ProcessRegistry persistence + Clarify + Delegation.

require "json"
require "fileutils"
require "tmpdir"
require "brute"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/process_registry"
require_relative "#{ROOT}/tools/process"
require_relative "#{ROOT}/middleware/process_registry"
require_relative "#{ROOT}/tools/clarify"
require_relative "#{ROOT}/middleware/clarify"
require_relative "#{ROOT}/delegation"
require_relative "#{ROOT}/tools/delegate_task"
require_relative "#{ROOT}/middleware/delegation"

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
  Dir.mktmpdir("hermes-autonomy2-test")
end

puts "ProcessRegistry persistence"
test "spawn persists an entry; completions fire once with the output tail" do
  d = fresh_dir
  reg = Hermes::ProcessRegistry.new(log_dir: d)
  entry = reg.spawn("echo done-marker", notify: true)
  assert reg.tracked.key?(entry.session_id)

  # wait for exit
  30.times { break unless entry.alive?; sleep 0.1 }
  fired = []
  Hermes::ProcessRegistry.check_completions(log_dir: d) { |e| fired << e }
  assert_equal 1, fired.size
  assert fired.first["output_tail"].include?("done-marker")
  # second check — already notified
  fired2 = []
  Hermes::ProcessRegistry.check_completions(log_dir: d) { |e| fired2 << e }
  assert fired2.empty?
end

test "no notify armed → no completion event" do
  d = fresh_dir
  reg = Hermes::ProcessRegistry.new(log_dir: d)
  entry = reg.spawn("true", notify: false)
  30.times { break unless entry.alive?; sleep 0.1 }
  fired = []
  Hermes::ProcessRegistry.check_completions(log_dir: d) { |e| fired << e }
  assert fired.empty?
end

puts "Clarify"
test "choices capped at 4, first labeled Recommended, answer returned" do
  tool = HermesTools::Clarify.new(prompter: ->(_q, choices, _multi) { choices[1] })
  r = JSON.parse(tool.call("question" => "which db?", "choices" => %w[postgres mysql sqlite redis mongo]))
  assert_equal 4, r["choices_offered"].size
  assert r["choices_offered"].first.include?("(Recommended)")
  assert r["choices_offered"].first.include?("postgres")
  assert_equal "mysql", r["user_response"]
end

test "no answer → sentinel; unavailable context → refusal" do
  tool = HermesTools::Clarify.new(prompter: ->(_q, _c, _m) { nil })
  r = JSON.parse(tool.call("question" => "q?"))
  assert r["user_response"].include?("did not respond")

  blocked = HermesTools::Clarify.new(unavailable_reason: "[clarify prompt could not be delivered]")
  r2 = JSON.parse(blocked.call("question" => "q?"))
  assert r2["error"].include?("could not be delivered")
end

test "middleware installs the tool; unattended installs the sentinel variant" do
  env = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  env[:messages].user("hi")
  Hermes::Middleware::Clarify.new(->(env) {}, prompter: ->(_q, c, _m) { c.first }).call(env)
  tool = env[:provided_tools].find { |t| t.name == "clarify" }
  assert tool

  env2 = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  env2[:messages].user("hi")
  Hermes::Middleware::Clarify.new(->(env) {}, unattended: true).call(env2)
  tool2 = env2[:provided_tools].find { |t| t.name == "clarify" }
  r = JSON.parse(tool2.call("question" => "anything?"))
  assert r["error"]
end

puts "Delegation"
test "sync run returns the result schema" do
  d = fresh_dir
  del = Hermes::Delegation.new(dir: d)
  factory = ->(goal:, context:, role:, output_schema:) {
    { "status" => "completed", "summary" => "did: #{goal}", "api_calls" => 3, "duration_seconds" => 0.1, "exit_reason" => "completed" }
  }
  tool = HermesTools::DelegateTask.new(delegation: del, run_sync: factory, main_rb: "main.rb", depth: 1)
  r = JSON.parse(tool.call("goal" => "summarize the repo"))
  assert_equal "completed", r["results"].first["status"]
  assert r["results"].first["summary"].include?("summarize the repo")
end

test "batch over the cap is rejected up front" do
  del = Hermes::Delegation.new(dir: fresh_dir)
  tool = HermesTools::DelegateTask.new(delegation: del, run_sync: ->(**_) { {} }, main_rb: "main.rb")
  r = JSON.parse(tool.call("tasks" => 4.times.map { |i| { "goal" => "g#{i}" } }))
  refute r["success"]
  assert r["error"].include?("max_concurrent_children")
end

test "background dispatch registers a running record (no spawn at capacity)" do
  d = fresh_dir
  del = Hermes::Delegation.new(dir: d)
  tool = HermesTools::DelegateTask.new(delegation: del, run_sync: ->(**_) { {} }, main_rb: "main.rb")
  # capacity fake: fill the ledger with running records
  3.times do |i|
    rec = del.records
    rec["fake-#{i}"] = { "id" => "fake-#{i}", "goal" => "x", "role" => "leaf", "status" => "running", "dispatched_at" => Time.now.to_f, "delivered" => false }
    del.save_records(rec)
  end
  r = JSON.parse(tool.call("goal" => "new task"))
  refute r["success"]
  assert r["error"].include?("at capacity")
end

test "completion flows: complete → completions → mark_delivered" do
  d = fresh_dir
  del = Hermes::Delegation.new(dir: d)
  rec = del.records
  rec["deleg_abcd"] = { "id" => "deleg_abcd", "goal" => "x", "role" => "leaf", "status" => "running", "dispatched_at" => Time.now.to_f, "delivered" => false }
  del.save_records(rec)
  del.complete("deleg_abcd", status: "completed", summary: "the answer")
  comps = del.completions
  assert_equal 1, comps.size
  assert_equal "the answer", del.result_for("deleg_abcd")["summary"]
  del.mark_delivered("deleg_abcd")
  assert del.completions.empty?
end

test "summary spill over 24k" do
  d = fresh_dir
  del = Hermes::Delegation.new(dir: d)
  del.records["x"] = { "id" => "x", "status" => "running", "delivered" => false }
  del.complete("x", status: "completed", summary: "y" * 30_000)
  result = del.result_for("x")
  assert result["summary"].include?("summary truncated")
  assert result["spill"]
  assert_equal 30_000, File.read(result["spill"]).length
end

test "steer writes a file the child drains" do
  d = fresh_dir
  del = Hermes::Delegation.new(dir: d)
  del.steer("deleg_1", "change course")
  assert_equal "change course", del.steer_for("deleg_1")
  assert del.steer_for("deleg_1").nil?
end

puts "\n#{$count - $failures.size}/#{$count} passed"
exit($failures.empty? ? 0 : 1)
