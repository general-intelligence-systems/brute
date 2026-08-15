# frozen_string_literal: true

# Plain-ruby test harness for Hermes::Review (the second-agent learning loop).

require "json"
require "fileutils"
require "tmpdir"
require "brute"
require "brute/turn/pipeline"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/review"
require_relative "#{ROOT}/memory_store"
require_relative "#{ROOT}/write_approval"
require_relative "#{ROOT}/tools/memory"
require_relative "#{ROOT}/middleware/tool_pipeline"

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
  raise "expected #{exp.inspect}, got #{act.inspect}" unless exp == act
end

def refute_equal(exp, act)
  raise "expected NOT #{act.inspect}" if exp == act
end

def fresh_dir
  Dir.mktmpdir("hermes-review-test")
end

def user(text) = Brute::Message.new(role: :user, content: text)
def assistant(text) = Brute::Message.new(role: :assistant, content: text)

puts "select_prompt"
test "memory / skills / combined + whitelist suffix" do
  assert Hermes::Review.select_prompt(review_memory: true, review_skills: false).include?("consider saving to memory")
  assert Hermes::Review.select_prompt(review_memory: false, review_skills: true).include?("update the skill library")
  both = Hermes::Review.select_prompt(review_memory: true, review_skills: true)
  assert both.include?("update two things")
  assert both.include?("You can only call memory and skill management tools")
end

test "focus paragraph appended" do
  p = Hermes::Review.select_prompt(review_memory: true, review_skills: false, focus: "watch the API usage")
  assert p.include?("user explicitly requested this review")
  assert p.include?("watch the API usage")
end

puts "digest"
test "short histories pass through untouched" do
  msgs = [user("a"), assistant("b")]
  assert_equal msgs, Hermes::Review.digest(msgs)
end

test "long history collapses to digest + tail of 24, never starting with a tool message" do
  msgs = []
  15.times do |i|
    msgs << user("question #{i}")
    msgs << Brute::Message.new(role: :assistant, content: "",
      tool_calls: [Brute::ToolCall.new(id: "t#{i}", name: "terminal", arguments: { "command" => "ls" })])
    msgs << Brute::Message.new(role: :tool, content: "output #{i}", tool_call_id: "t#{i}")
    msgs << assistant("answer #{i}")
  end
  out = Hermes::Review.digest(msgs)
  assert out.first.content.include?("[Earlier conversation digest")
  assert out.first.content.include?("USER: question 0")
  assert out.first.content.include?("ASSISTANT[tools: terminal]")
  assert out.size <= 26, "digest + tail too big: #{out.size}"
  refute_equal :tool, out[1].role
  # role alternation at the seam
  assert_equal :user, out.first.role
end

puts "summarize"
def scripted_review_agent(memory_dir, script_actions)
  store = Hermes::MemoryStore.new(dir: memory_dir).load_from_disk
  tools = [HermesTools::Memory.new(store)]
  calls = 0
  terminal = ->(env) do
    calls += 1
    if calls <= script_actions.size
      action = script_actions[calls - 1]
      env[:messages] << Brute::Message.new(role: :assistant, content: "",
        tool_calls: [Brute::ToolCall.new(id: "tc#{calls}", name: "memory", arguments: action)])
    else
      env[:messages] << Brute::Message.new(role: :assistant, content: "Nothing to save.")
    end
  end
  Brute.agent
    .use(Brute::Middleware::Loop::ToolResult)
    .use(Brute::Middleware::MaxIterations, max_iterations: 16)
    .use(Hermes::Middleware::ToolPipeline, tools: tools, pipeline: Brute::Turn::Pipeline.new)
    .run(terminal)
end

test "full flow: review agent writes memory; summary lists the add" do
  d = fresh_dir
  history = [user("I prefer dark themes in all my editors"), assistant("Noted.")]
  agent = scripted_review_agent(d, [{ "target" => "user", "action" => "add", "content" => "prefers dark themes" }])
  prompt = Hermes::Review.select_prompt(review_memory: true, review_skills: false)
  review_env = agent.start(history + [user(prompt)])

  assert File.read(File.join(d, "USER.md")).include?("dark themes")
  actions = Hermes::Review.summarize(review_env[:messages], from: history.size + 1)
  assert actions.include?("User profile updated"), actions.inspect
end

test "summarize only counts fresh, successful, whitelisted tool results" do
  d = fresh_dir
  history = [user("hi"), assistant("hello")]
  agent = scripted_review_agent(d, [{ "target" => "memory", "action" => "add", "content" => "fact" }])
  review_env = agent.start(history + [user("review prompt")])
  # from: 0 would re-scan history (no tool results there, but proves the slice)
  assert_equal [], Hermes::Review.summarize(review_env[:messages], from: 0) - Hermes::Review.summarize(review_env[:messages], from: 0)
  early = Hermes::Review.summarize(review_env[:messages], from: review_env[:messages].size)
  assert_equal [], early
end

test "verbose mode previews content; off returns nothing" do
  d = fresh_dir
  history = [user("hi"), assistant("hello")]
  agent = scripted_review_agent(d, [{ "target" => "user", "action" => "add", "content" => "likes tabs not spaces" }])
  review_env = agent.start(history + [user("p")])
  from = history.size + 1
  verbose = Hermes::Review.summarize(review_env[:messages], from: from, notifications: "verbose")
  assert verbose.any? { |a| a.include?("User profile ➕ likes tabs not spaces") }, verbose.inspect
  off = Hermes::Review.summarize(review_env[:messages], from: from, notifications: "off")
  assert_equal [], off
end

puts "\n#{$count - $failures.size}/#{$count} passed"
exit($failures.empty? ? 0 : 1)
