# frozen_string_literal: true

# Plain-ruby test harness for Todo + TokenUsage.

require "json"
require "brute"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/todo_store"
require_relative "#{ROOT}/tools/todo"
require_relative "#{ROOT}/middleware/todo"
require_relative "#{ROOT}/middleware/token_usage"

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

def refute(cond, msg = "expected falsy")
  raise msg if cond
end

puts "TodoStore"
test "write replaces wholesale; merge updates by id" do
  s = Hermes::TodoStore.new
  s.write([{ id: "a", content: "first", status: "pending" }])
  s.write([{ id: "b", content: "second", status: "in_progress" }])
  assert_eq 1, s.items.size
  s.write([{ id: "b", status: "completed" }], merge: true)
  assert_eq "completed", s.items.first[:status]
  assert_eq "second", s.items.first[:content], "merge must preserve unprovided fields"
end

test "dedup by id, last wins; caps respected" do
  s = Hermes::TodoStore.new
  s.write([
    { id: "a", content: "v1", status: "pending" },
    { id: "a", content: "v2", status: "completed" },
  ])
  assert_eq [{ id: "a", content: "v2", status: "completed" }], s.items
  s.write(300.times.map { |i| { id: "t#{i}", content: "x", status: "pending" } })
  assert_eq 256, s.items.size
end

test "invalid status defaults to pending; empty items dropped" do
  s = Hermes::TodoStore.new
  s.write([{ id: "a", content: "x", status: "bogus" }, { id: "", content: "y" }])
  assert_eq 1, s.items.size
  assert_eq "pending", s.items.first[:status]
end

test "summary counts by status" do
  s = Hermes::TodoStore.new
  s.write([
    { id: "a", content: "1", status: "pending" },
    { id: "b", content: "2", status: "in_progress" },
    { id: "c", content: "3", status: "completed" },
    { id: "d", content: "4", status: "cancelled" },
  ])
  assert_eq({ total: 4, pending: 1, in_progress: 1, completed: 1, cancelled: 1 }, s.summary)
end

test "injection carries only active items with the verbatim header and markers" do
  s = Hermes::TodoStore.new
  s.write([
    { id: "a", content: "do this", status: "pending" },
    { id: "b", content: "doing that", status: "in_progress" },
    { id: "c", content: "done", status: "completed" },
  ])
  block = s.format_for_injection
  assert block.start_with?("[Your active task list was preserved across context compression]")
  assert block.include?("[ ] do this")
  assert block.include?("[>] doing that")
  refute block.include?("done")
  empty = Hermes::TodoStore.new
  assert empty.format_for_injection.nil?
end

test "hydrate rebuilds from the latest todo tool result" do
  s = Hermes::TodoStore.new
  s.hydrate([
    JSON.dump("todos" => [{ "id" => "old", "content" => "stale", "status" => "pending" }]),
    JSON.dump("todos" => [{ "id" => "new", "content" => "fresh", "status" => "in_progress" }]),
  ])
  assert_eq [{ id: "new", content: "fresh", status: "in_progress" }], s.items
end

puts "todo tool"
test "read returns todos + summary; write then read round-trips" do
  tool = HermesTools::Todo.new(Hermes::TodoStore.new)
  JSON.parse(tool.call("todos" => [{ "id" => "a", "content" => "write tests", "status" => "pending" }]))
  r = JSON.parse(tool.call({}))
  assert_eq "write tests", r["todos"].first["content"]
  assert_eq 1, r["summary"]["pending"]
end

test "storeless tool reports unavailable" do
  r = JSON.parse(HermesTools::Todo.new.call({}))
  assert r["error"]
end

puts "Todo middleware"
test "installs the tool and hydrates the store from history" do
  env = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  env[:messages] << Brute::Message.new(role: :tool, content: JSON.dump("todos" => [{ "id" => "a", "content" => "resumed task", "status" => "pending" }]))
  env[:messages].user("continue")
  Hermes::Middleware::Todo.new(->(env) {}).call(env)
  assert env[:todo_store].has_items?
  assert_eq "resumed task", env[:todo_store].items.first[:content]
  assert env[:provided_tools].any? { |t| t.name == "todo" }
end

puts "TokenUsage"
test "estimates chars/4 and accumulates" do
  inner = ->(env) { env[:messages] << Brute::Message.new(role: :assistant, content: "x" * 40) }
  env = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  env[:messages].user("y" * 40)
  Hermes::Middleware::TokenUsage.new(inner).call(env)
  assert env[:usage][:total] > 0
  assert_eq :estimate, env[:usage][:source]
  assert env[:metadata][:usage][:calls] == 1
  assert env[:metadata][:usage][:total] == env[:usage][:total]
end

test "provider-reported usage wins over the estimate" do
  inner = ->(env) { env[:response_usage] = { input: 100, output: 25 } }
  env = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  env[:messages].user("hi")
  Hermes::Middleware::TokenUsage.new(inner).call(env)
  assert_eq({ input: 100, output: 25, total: 125, source: :provider }, env[:usage])
end

puts "\n#{$count - $failures.size}/#{$count} passed"
exit($failures.empty? ? 0 : 1)
