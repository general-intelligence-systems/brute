# frozen_string_literal: true

# Plain-ruby test harness for Interrupt / IterationBudget / Steering.

require "json"
require "brute"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/middleware/interrupt"
require_relative "#{ROOT}/middleware/iteration_budget"
require_relative "#{ROOT}/middleware/steering"

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

def base_env
  env = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  env[:messages].user("hi")
  env
end

puts "Interrupt"
test "no flag → inner runs" do
  called = false
  Hermes::Interrupt.clear!
  Hermes::Middleware::Interrupt.new(->(env) { called = true }).call(base_env)
  assert called
end

test "flag set → should_exit, inner skipped, status event" do
  called = false
  Hermes::Interrupt.request!
  env = base_env
  Hermes::Middleware::Interrupt.new(->(env) { called = true }).call(env)
  Hermes::Interrupt.clear!
  assert !called
  assert_eq({ reason: "interrupted" }, env[:should_exit])
  assert env[:events].any? { |e| e[:type] == :status }
end

puts "IterationBudget"
test "under the cap the inner stack runs normally" do
  calls = 0
  budget = Hermes::Middleware::IterationBudget.new(->(env) { calls += 1 }, max_iterations: 3)
  3.times { budget.call(base_env) }
  assert_eq 3, calls
end

test "at cap+1 the grace call runs once, tool-free, with the verbatim request" do
  calls = 0
  budget = Hermes::Middleware::IterationBudget.new(->(env) { calls += 1 }, max_iterations: 2)
  2.times { budget.call(base_env) }
  env = base_env
  env[:current_iteration] = 3
  budget.call(env)
  assert_eq 3, calls, "grace call should run the inner stack once"
  assert env[:tool_free]
  assert_eq({ reason: "max_iterations" }, env[:should_exit])
  last_user = env[:messages].reverse.find { |m| m.role == :user }
  assert last_user.content.include?("maximum number of tool-calling iterations")
  assert last_user.content.include?("without calling any more tools")
end

test "grace fires only once per budget" do
  calls = 0
  budget = Hermes::Middleware::IterationBudget.new(->(env) { calls += 1 }, max_iterations: 1)
  budget.call(base_env) # iteration 1
  env = base_env
  env[:current_iteration] = 2
  budget.call(env) # grace (inner call #2)
  budget.call(env) # no second grace
  assert_eq 2, calls
  users = env[:messages].count { |m| m.role == :user && m.content.include?("maximum number") }
  assert_eq 1, users
end

test "refund gives back an iteration" do
  budget = Hermes::Middleware::IterationBudget.new(->(env) {}, max_iterations: 2)
  env = base_env
  env[:current_iteration] = 3
  budget.refund(env)
  assert_eq 2, env[:current_iteration]
  budget.refund(env)
  budget.refund(env)
  assert_eq 1, env[:current_iteration], "refund never goes below 1"
end

puts "Steering"
def env_with_tool_message
  env = base_env
  env[:messages] << Brute::Message.new(role: :assistant, content: "",
    tool_calls: [Brute::ToolCall.new(id: "t1", name: "terminal", arguments: {})])
  env[:messages] << Brute::Message.new(role: :tool, content: "ls output", tool_call_id: "t1")
  env
end

test "steer is appended to the last tool message with the verbatim marker" do
  Hermes::Steering.clear!
  Hermes::Steering.steer("focus on the tests")
  env = env_with_tool_message
  Hermes::Middleware::Steering.new(->(env) {}).call(env)
  tool = env[:messages].reverse.find { |m| m.role == :tool }
  assert tool.content.include?("ls output")
  assert tool.content.include?("[OUT-OF-BAND USER MESSAGE")
  assert tool.content.include?("focus on the tests")
  assert tool.content.include?("[/OUT-OF-BAND USER MESSAGE]")
  # no new user message was injected
  assert_eq 1, env[:messages].count { |m| m.role == :user }
  assert Hermes::Steering.pending.empty?
end

test "steer with no tool message stays pending (never injected as user)" do
  Hermes::Steering.clear!
  Hermes::Steering.steer("later")
  env = base_env # only a user message
  Hermes::Middleware::Steering.new(->(env) {}).call(env)
  assert_eq 1, env[:messages].count { |m| m.role == :user }
  assert_eq ["later"], Hermes::Steering.pending
  Hermes::Steering.clear!
end

test "redirect appends a user correction with the interruption checkpoint" do
  Hermes::Steering.clear!
  Hermes::Steering.redirect("actually, use postgres")
  env = env_with_tool_message
  before = env[:messages].size
  Hermes::Middleware::Steering.new(->(env) {}).call(env)
  assert_eq before + 1, env[:messages].size
  last = env[:messages].last
  assert_eq :user, last.role
  assert last.content.include?("[This response was interrupted by a user correction.]")
  assert last.content.include?("actually, use postgres")
  # alternation: tool → user is valid
  assert_eq :tool, env[:messages][-2].role
end

puts "\n#{$count - $failures.size}/#{$count} passed"
exit($failures.empty? ? 0 : 1)
