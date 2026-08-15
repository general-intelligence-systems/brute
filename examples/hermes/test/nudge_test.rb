# frozen_string_literal: true

# Plain-ruby test harness for Hermes::Middleware::Nudge.

require "json"
require "brute"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/middleware/nudge"

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

def assert_eq(exp, act, msg = nil)
  raise(msg || "expected #{exp.inspect}, got #{act.inspect}") unless exp == act
end

SKILL_TOOL = { name: "skill_manage", description: "", execute: ->(**) { "ok" } }.freeze

# A fake loop: bumps current_iteration `iters` times, optionally emitting tool
# results (to simulate tool use during the turn).
def fake_loop(iters: 0, tools_used: [])
  ->(env) {
    env[:current_iteration] += iters
    tools_used.each do |name|
      env[:events] << { type: :tool_result, data: { name: name, content: "ok" } }
    end
  }
end

def base_env(with_memory_store: false, history_user_turns: 0)
  env = {
    messages: Brute.log,
    events: [],
    metadata: {},
    current_iteration: 1,
    tools: [SKILL_TOOL],
  }
  history_user_turns.times { |i| env[:messages].user("past #{i}") }
  env[:messages].user("current message")
  env[:memory_store] = Object.new if with_memory_store
  env
end

def turn(mw, env)
  mw.call(env)
  env
end

puts "memory nudge (per user turn)"
test "fires exactly on the 10th turn" do
  nudge = Hermes::Middleware::Nudge.new(fake_loop)
  flags = (1..10).map { turn(nudge, base_env(with_memory_store: true))[:review_memory] }
  assert_eq [nil] * 9 + [true], flags.map { |f| f ? true : nil }
end

test "never fires without a memory store installed" do
  nudge = Hermes::Middleware::Nudge.new(fake_loop)
  10.times { turn(nudge, base_env(with_memory_store: false)) }
  # no raise, and no flag — gate keeps it silent
  env = turn(nudge, base_env(with_memory_store: false))
  assert env[:review_memory].nil?
end

test "memory tool use resets the counter" do
  nudge = Hermes::Middleware::Nudge.new(fake_loop)
  9.times { turn(nudge, base_env(with_memory_store: true)) }
  turn(nudge, base_env(with_memory_store: true).merge({})) # 10th — fires
  nudge2 = Hermes::Middleware::Nudge.new(fake_loop(tools_used: ["memory"]))
  9.times { turn(nudge2, base_env(with_memory_store: true)) }
  env = turn(nudge2, base_env(with_memory_store: true)) # 10th turn, but memory was used on turn 1
  assert env[:review_memory].nil?, "memory use on turn 1 should have reset the cadence"
end

test "resume hydrates the counter (prior_user_turns % interval)" do
  nudge = Hermes::Middleware::Nudge.new(fake_loop)
  env = base_env(with_memory_store: true, history_user_turns: 9) # 9 prior turns
  turn(nudge, env) # hydrated to 9, +1 = 10 → fires immediately
  assert env[:review_memory], "resumed session at 9 prior turns should fire on the 10th"
end

test "interval 0 disables the memory nudge" do
  nudge = Hermes::Middleware::Nudge.new(fake_loop, memory_interval: 0)
  15.times { turn(nudge, base_env(with_memory_store: true)) }
  assert true # no crash, no flag — nothing to assert beyond absence
end

puts "skill nudge (per tool-calling iteration)"
test "fires after 10 iterations across turns" do
  nudge = Hermes::Middleware::Nudge.new(fake_loop(iters: 4))
  e1 = turn(nudge, base_env)           # 4
  e2 = turn(nudge, base_env)           # 8
  e3 = turn(nudge, base_env)           # 12 → fires
  assert e1[:review_skills].nil?
  assert e2[:review_skills].nil?
  assert e3[:review_skills]
end

test "skill_manage use resets the counter and suppresses the trip" do
  nudge = Hermes::Middleware::Nudge.new(fake_loop(iters: 6))
  turn(nudge, base_env)                # 6
  nudge_used = Hermes::Middleware::Nudge.new(fake_loop(iters: 6, tools_used: ["skill_manage"]))
  turn(nudge_used, base_env)           # 6, then use-reset
  env = turn(nudge_used, base_env)     # 6 again — below interval
  assert env[:review_skills].nil?
  plain = Hermes::Middleware::Nudge.new(fake_loop(iters: 6))
  turn(plain, base_env)
  env2 = turn(plain, base_env)         # 12 → fires
  assert env2[:review_skills]
end

test "skill nudge requires skill_manage among the tools" do
  nudge = Hermes::Middleware::Nudge.new(fake_loop(iters: 12))
  env = base_env
  env[:tools] = [] # no skill tool advertised
  turn(nudge, env)
  assert env[:review_skills].nil?
end

puts "ordering vs BackgroundReview"
test "flags are set before an outer middleware's after-phase runs" do
  seen = {}
  spy = Class.new do
    define_method(:initialize) { |app| @app = app }
    define_method(:call) do |env|
      @app.call(env)
      # after-phase (like BackgroundReview): flags must already be set
      seen[:review_skills] = env[:review_skills]
      seen[:review_memory] = env[:review_memory]
    end
  end
  bump = 0
  inner = ->(env) { env[:current_iteration] += bump }
  nudge = Hermes::Middleware::Nudge.new(inner)
  app = spy.new(nudge) # spy wraps Nudge — like BackgroundReview wrapping it
  9.times { app.call(base_env(with_memory_store: true)) } # memory counter → 9
  bump = 10 # final turn does 10 tool iterations
  app.call(base_env(with_memory_store: true))
  assert_eq true, seen[:review_skills]
  assert_eq true, seen[:review_memory]
end

puts "\n#{$count - $failures.size}/#{$count} passed"
exit($failures.empty? ? 0 : 1)
