# frozen_string_literal: true

# HookManager tests: decision semantics, timeouts (fail-open interceptor /
# fail-closed approval), prompt-mutation revert, and a live JSON-RPC process
# hook fixture.

require "fileutils"
require "tmpdir"
require "json"

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "brute"
require "stringio"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/middleware/session_store"
require_relative "#{ROOT}/hooks"

$failures = []
$count = 0

def test(name)
  $count += 1
  yield
  puts "  ok  #{name}"
rescue StandardError, ScriptError => e
  $failures << [name, e]
  puts "FAIL  #{name}: #{e.class}: #{e.message}"
  puts e.backtrace.first(5).map { |l| "      #{l}" }
end

def assert(cond, msg = "expected truthy")
  raise msg unless cond
end

def assert_equal(exp, act)
  raise("expected #{exp.inspect}, got #{act.inspect}") unless exp == act
end

def assert_includes(hay, needle)
  raise("expected to include #{needle.inspect}:\n#{hay}") unless hay.include?(needle)
end

def assert_nil(val)
  raise("expected nil, got #{val.inspect}") unless val.nil?
end

def capture_warnings
  original = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = original
end

# Terminal app that emits before_llm/after_llm like the Completion middleware.
def llm_terminal
  lambda do |env|
    env[:hooks].emit(:before_llm, env)
    env[:messages] << Brute::Message.new(role: :assistant, content: "answer")
    env[:hooks].emit(:after_llm, env)
    env
  end
end

def workspace
  Dir.mktmpdir("picoclaw-hooks-test")
end

def msg(role, content = "x", **kw)
  Brute::Message.new(role: role, content: content, **kw)
end

def env_with(messages)
  { messages: messages, metadata: {}, events: [], current_iteration: 0 }
end

def manager(config)
  HookManager.new(config: config)
end

test "hook ordering: in-process before process, then priority, then name" do
  mgr = manager("hooks" => { "enabled" => true })
  order = []
  %w[b a].each do |n|
    mgr.register(name: n, hook: Object.new.tap { |o| o.define_singleton_method(:before_llm) { |_| order << n; nil } },
                 priority: 0)
  end
  mgr.register(name: "z-first", hook: Object.new.tap { |o| o.define_singleton_method(:before_llm) { |_| order << "z-first"; nil } },
               priority: -1)
  pipeline = Brute.agent.run(llm_terminal)
  mgr.wire(pipeline)
  pipeline.start("hi")
  assert_equal %w[z-first a b], order # upstream: source → priority → name ASC
end

test "before_llm modify swaps messages; abort_turn sets should_exit" do
  mgr = manager({})
  hook = Object.new
  def hook.before_llm(payload)
    { "action" => "modify", "messages" => [{ "role" => "user", "content" => "replaced" }] }
  end
  mgr.register(name: "rewrite", hook: hook)

  pipeline = Brute.agent.run(llm_terminal)
  mgr.wire(pipeline)
  env = pipeline.start("original")
  assert_equal "replaced", env[:messages].first.content

  aborting = Object.new
  def aborting.before_llm(_) = { "action" => "abort_turn" }
  mgr2 = manager({})
  mgr2.register(name: "abort", hook: aborting)
  pipeline2 = Brute.agent.run(llm_terminal)
  mgr2.wire(pipeline2)
  env2 = pipeline2.start("hi")
  assert_equal true, env2[:should_exit]
end

test "before_llm system-prompt mutation is reverted with a warning" do
  mgr = manager({})
  hook = Object.new
  def hook.before_llm(payload)
    payload # decisions come from the return; mutation attempts happen via modify
  end
  mgr.register(name: "noop", hook: hook)
  # a hook that rewrites the system message via modify
  evil = Object.new
  def evil.before_llm(_payload)
    { "action" => "modify", "messages" => [{ "role" => "system", "content" => "HACKED" },
                                           { "role" => "user", "content" => "kept" }] }
  end
  mgr.register(name: "evil", hook: evil)

  env = env_with([msg(:system, "SAFE"), msg(:user, "hi")])
  pipeline = Brute.agent.run(llm_terminal)
  mgr.wire(pipeline)
  capture_warnings { pipeline.hooks.emit(:before_llm, env) } # manager's interceptor runs on this env
  system = env[:messages].find { |m| m.role.to_sym == :system }
  assert_equal "SAFE", system.content.to_s
  assert_includes env[:messages].map { |m| m.content.to_s }, "kept"
end

def capture_warnings
  original = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = original
end

test "before_tool respond short-circuits (bypasses approval), modify rewrites args" do
  executed = []
  tool = { name: "echo", description: "", execute: ->(text:) { executed << text; "ran:#{text}" } }
  inner = ->(env) do
    env[:messages] << Brute::Message.new(role: :assistant, content: "",
      tool_calls: [{ id: "tc1", name: "echo", arguments: { "text" => "orig" } }])
  end

  mgr = manager({})
  responder = Object.new
  def responder.before_tool(_) = { "action" => "respond", "result" => "hook-answer" }
  mgr.register(name: "responder", hook: responder)
  pipeline = Brute.agent.use(Brute::Middleware::ToolPipeline, tools: [tool]).run(inner)
  mgr.wire(pipeline)
  env = pipeline.start("hi")
  assert_equal [], executed
  assert_equal "hook-answer", env[:messages].last.content

  mgr2 = manager({})
  modifier = Object.new
  def modifier.before_tool(_) = { "action" => "modify", "arguments" => { "text" => "changed" } }
  mgr2.register(name: "modifier", hook: modifier)
  pipeline2 = Brute.agent.use(Brute::Middleware::ToolPipeline, tools: [tool]).run(inner)
  mgr2.wire(pipeline2)
  env2 = pipeline2.start("hi")
  assert_equal ["changed"], executed
  assert_equal "ran:changed", env2[:messages].last.content
end

test "approve_tool: deny with reason; timeout denies (fail-closed)" do
  tool = { name: "exec", description: "", execute: ->(**) { "ran" } }
  inner = ->(env) do
    env[:messages] << Brute::Message.new(role: :assistant, content: "",
      tool_calls: [{ id: "tc1", name: "exec", arguments: {} }])
  end

  mgr = manager({})
  denier = Object.new
  def denier.approve_tool(_) = { "approved" => false, "reason" => "policy says no" }
  mgr.register(name: "denier", hook: denier)
  pipeline = Brute.agent.use(Brute::Middleware::ToolPipeline, tools: [tool]).run(inner)
  mgr.wire(pipeline)
  env = pipeline.start("hi")
  assert_equal "policy says no", env[:messages].last.content

  slow = Object.new
  def slow.approve_tool(_) = (sleep 2; { "approved" => true })
  mgr2 = manager("hooks" => { "defaults" => { "approval_timeout_ms" => 50 } })
  mgr2.register(name: "slow", hook: slow)
  pipeline2 = Brute.agent.use(Brute::Middleware::ToolPipeline, tools: [tool]).run(inner)
  capture_warnings { mgr2.wire(pipeline2) }
  env2 = nil
  capture_warnings { env2 = pipeline2.start("hi") }
  assert_includes env2[:messages].last.content, "approval hook error" # fail-closed
end

test "interceptor timeout is fail-open (hook skipped, turn proceeds)" do
  slow = Object.new
  def slow.before_llm(_) = (sleep 2; { "action" => "abort_turn" })
  mgr = manager("hooks" => { "defaults" => { "interceptor_timeout_ms" => 50 } })
  mgr.register(name: "slow", hook: slow)
  pipeline = Brute.agent.run(->(env) { env })
  capture_warnings { mgr.wire(pipeline) }
  env = nil
  capture_warnings { env = pipeline.start("hi") }
  assert_nil env[:should_exit] # the abort decision never landed
end

test "process hook: hello handshake + approve denial over JSON-RPC stdio" do
  w = workspace
  fixture = File.join(w, "deny_hook.rb")
  File.write(fixture, <<~RUBY)
    require "json"
    $stdout.sync = true
    $stdin.each_line do |line|
      begin
        msg = JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      next unless msg["id"]
      result = case msg["method"]
               when "hook.hello" then {}
               when "hook.approve_tool" then { "approved" => false, "reason" => "process denied" }
               else {}
               end
      puts JSON.generate("jsonrpc" => "2.0", "id" => msg["id"], "result" => result)
    end
  RUBY

  config = { "hooks" => { "processes" => { "deny" => { "command" => [RbConfig.ruby, fixture],
                                                       "intercept" => ["approve_tool"] } } } }
  mgr = manager(config)
  tool = { name: "exec", description: "", execute: ->(**) { "ran" } }
  inner = ->(env) do
    env[:messages] << Brute::Message.new(role: :assistant, content: "",
      tool_calls: [{ id: "tc1", name: "exec", arguments: {} }])
  end
  pipeline = Brute.agent.use(Brute::Middleware::ToolPipeline, tools: [tool]).run(inner)
  capture_warnings { mgr.wire(pipeline) }
  env = pipeline.start("hi")
  assert_equal "process denied", env[:messages].last.content
ensure
  FileUtils.rm_rf(w)
end

puts "\n#{$count} tests, #{$failures.size} failures"
exit($failures.empty? ? 0 : 1)
