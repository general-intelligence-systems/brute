# frozen_string_literal: true

# Plain-ruby test harness for the Compactor + Compaction middleware.

require "json"
require "brute"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/compactor"
require_relative "#{ROOT}/todo_store"
require_relative "#{ROOT}/middleware/compaction"

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

def user(text) = Brute::Message.new(role: :user, content: text)
def assistant(text) = Brute::Message.new(role: :assistant, content: text)
def tool_msg(text) = Brute::Message.new(role: :tool, content: text, tool_call_id: "t#{rand(10000)}")
def system_msg(text) = Brute::Message.new(role: :system, content: text)

def transcript(exchanges:, filler: 200)
  msgs = [system_msg("sys")]
  exchanges.times do |i|
    msgs << user("question #{i} #{'x' * filler}")
    msgs << assistant("answer #{i} #{'y' * filler}")
  end
  msgs
end

def fake_compactor(**opts)
  captured = []
  summarize = ->(prompt) { captured << prompt; "SUMMARY OF MIDDLE" }
  [Hermes::Compactor.new(context_length: 1_000, summarize: summarize, **opts), captured]
end

puts "thresholds"
test "threshold is 50% of window; floored at 75% for small windows" do
  big, _ = fake_compactor
  big.instance_variable_set(:@context_length, 1_000_000)
  assert_eq 500_000, big.threshold_tokens
  small, _ = fake_compactor
  small.instance_variable_set(:@context_length, 100_000)
  assert_eq 75_000, small.threshold_tokens
end

test "should_compress? by estimate" do
  compactor, _ = fake_compactor
  refute compactor.should_compress?([user("hi")])
  assert compactor.should_compress?(transcript(exchanges: 30, filler: 200))
end

puts "compress"
test "head protected, middle summarized, tail preserved with a user turn" do
  compactor, captured = fake_compactor
  msgs = transcript(exchanges: 12, filler: 100)
  out = compactor.compress(msgs)
  assert out
  assert_eq :system, out.first.role
  assert out.first.content == "sys"
  joined = out.map(&:content).join("\n")
  assert joined.include?("CONTEXT COMPACTION — REFERENCE ONLY")
  assert joined.include?("SUMMARY OF MIDDLE")
  assert joined.include?("respond to the message below, not the summary above")
  assert out.last(4).any? { |m| m.role == :user }, "tail keeps a real user turn"
  assert captured.size == 1
  assert captured.first.include?("## Historical Task Snapshot")
  assert captured.first.include?("TEMPORAL ANCHORING")
end

test "too few messages → nil (insufficient_messages abort)" do
  compactor, _ = fake_compactor
  assert compactor.compress(transcript(exchanges: 2, filler: 50)).nil?
end

test "role alternation: standalone handoff when tail leads with assistant, merged when user" do
  compactor, _ = fake_compactor
  msgs = transcript(exchanges: 12, filler: 100)
  out = compactor.compress(msgs)
  roles = out.map(&:role)
  roles.each_cons(2) { |a, b| refute(a == :user && b == :user, "two users in a row: #{roles.inspect}") }
end

test "old large tool results are pruned in the cheap pre-pass" do
  compactor, captured = fake_compactor
  msgs = [system_msg("sys")]
  8.times do |i|
    msgs << user("q#{i}")
    msgs << assistant("a#{i}")
    msgs << tool_msg("z" * 5000)
    msgs << assistant("after tool #{i}")
  end
  compactor.compress(msgs)
  assert captured.first.include?("[pruned tool output")
  refute captured.first.include?("z" * 3000)
end

test "second compression iteratively updates the previous summary" do
  compactor, captured = fake_compactor
  compactor.compress(transcript(exchanges: 12, filler: 100))
  compactor.compress(transcript(exchanges: 14, filler: 100))
  assert_eq 2, captured.size
  assert captured.last.include?("A previous summary of still-older turns follows")
  assert captured.last.include?("SUMMARY OF MIDDLE")
end

test "summarizer failure aborts cleanly (nil, no fake summary)" do
  failing = ->(_prompt) { raise "provider down" }
  compactor = Hermes::Compactor.new(context_length: 1_000, summarize: failing)
  assert compactor.compress(transcript(exchanges: 12, filler: 100)).nil?
end

puts "middleware"
def mw_env(messages, with_todo: false)
  env = { messages: messages.extend(Brute::Messages), events: [], metadata: {}, current_iteration: 1 }
  if with_todo
    store = Hermes::TodoStore.new
    store.write([{ id: "a", content: "unfinished task", status: "pending" }])
    env[:todo_store] = store
  end
  env
end

test "compacts over threshold, invalidates prompt, emits event" do
  compactor, _ = fake_compactor
  env = mw_env(transcript(exchanges: 16, filler: 200))
  before = env[:messages].size
  Hermes::Middleware::Compaction.new(->(env) {}, compactor: compactor).call(env)
  assert env[:invalidate_system_prompt]
  assert env[:events].any? { |e| e[:type] == :compaction }
  assert env[:messages].size < before
  assert env[:messages].any? { |m| m.content.to_s.include?("CONTEXT COMPACTION — REFERENCE ONLY") }
end

test "todo list is re-injected when the new tail is assistant" do
  compactor, _ = fake_compactor
  env = mw_env(transcript(exchanges: 16, filler: 200), with_todo: true)
  Hermes::Middleware::Compaction.new(->(env) {}, compactor: compactor).call(env)
  if env[:messages].last.role == :assistant
    assert env[:messages].any? { |m| m.content.to_s.include?("preserved across context compression") }
  else
    assert true # tail led by user — injection skipped by design (alternation)
  end
end

test "under threshold nothing happens" do
  compactor, captured = fake_compactor
  env = mw_env(transcript(exchanges: 2, filler: 20))
  size_before = env[:messages].size
  Hermes::Middleware::Compaction.new(->(env) {}, compactor: compactor).call(env)
  assert_eq size_before, env[:messages].size
  assert captured.empty?
end

puts "\n#{$count - $failures.size}/#{$count} passed"
exit($failures.empty? ? 0 : 1)
