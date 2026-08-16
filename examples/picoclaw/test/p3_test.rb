# frozen_string_literal: true

# delegate + seahorse tests (P3 remainder).

require "fileutils"
require "tmpdir"
require "json"

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "brute"
require "extralite"

ROOT = File.expand_path("..", __dir__)
%w[fs_sandbox diff_result exec_session web_http html_markdown skill_registries bm25 mcp_tool
   mcp_manager tool_search_tool_regex tool_search_tool_bm25 outbox message reaction send_file
   send_tts load_image cron_tool read_file write_file edit_file append_file list_dir exec
   find_skills install_skill spawn subagent spawn_status delegate short_grep short_expand
   tool_wrapper workspace_guard tool_policy].each { |f| require_relative "#{ROOT}/tools/#{f}" }
require_relative "#{ROOT}/cron"
%w[session_store memory_files skills_catalog token_estimator context_budget emergency_compression
   steering_loop state_manager cron_schedule model_router media fallback_chain subturns
   runtime_events evolution_log evolution_cold_path seahorse_context].each { |f| require_relative "#{ROOT}/middleware/#{f}" }

$failures = []
$count = 0

def test(name)
  $count += 1
  yield
  puts "  ok  #{name}"
rescue StandardError, ScriptError => e
  $failures << [name, e]
  puts "FAIL  #{name}: #{e.class}: #{e.message}"
  puts e.backtrace.first(6).map { |l| "      #{l}" }
end

def assert(cond, msg = "expected truthy")
  raise msg unless cond
end

def refute(cond, msg = "expected falsy")
  raise msg if cond
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

def workspace
  Dir.mktmpdir("picoclaw-p3-test")
end

def msg(role, content = "x", **kw)
  Brute::Message.new(role: role, content: content, **kw)
end

def env_with(messages)
  { messages: messages, metadata: {}, events: [], current_iteration: 0 }
end

# --- delegate --------------------------------------------------------------------

test "delegate: validation, self-refusal, allowlist, response prefix" do
  spawner = ->(_agent, task) { "child did: #{task}" }
  tool = Delegate.new(self_id: "main", spawner: spawner)
  assert_equal "agent_id is required and must be a non-empty string", tool.call("task" => "x")
  assert_equal "task is required and must be a non-empty string", tool.call("agent_id" => "research")
  assert_equal "cannot delegate to self", tool.call("agent_id" => "main", "task" => "x")
  assert_equal "[Response from agent \"research\"]\nchild did: summarize", tool.call("agent_id" => "research", "task" => "summarize")

  limited = Delegate.new(self_id: "main", spawner: spawner, allowlist: ["research"])
  assert_equal %(not allowed to delegate to agent "other"), limited.call("agent_id" => "other", "task" => "x")

  failing = Delegate.new(self_id: "main", spawner: ->(_a, _t) { raise "unknown agent \"nope\"" })
  assert_equal %(delegation to agent "nope" failed: unknown agent "nope"), failing.call("agent_id" => "nope", "task" => "x")
end

# --- seahorse ----------------------------------------------------------------------

def seahorse_engine(dir, summarize: nil)
  Seahorse::Engine.new(db_path: File.join(dir, "seahorse.db"),
                       summarize: summarize || ->(_p) { "summary text. Files: none. Expand for details about: chatter" })
end

test "seahorse: ingest → assemble round-trip" do
  w = workspace
  engine = seahorse_engine(w)
  engine.ingest("s", [msg(:user, "hello harbor"), msg(:assistant, "hi there")])
  assembled = engine.assemble("s", budget: 10_000)
  assert_equal %i[user assistant], assembled[:messages].map { |m| m.role.to_sym }
  assert_equal "hello harbor", assembled[:messages].first.content
  assert_equal "", assembled[:summary]
  engine.close
ensure
  FileUtils.rm_rf(w)
end

test "seahorse: leaf compaction folds old messages into a summary" do
  w = workspace
  engine = seahorse_engine(w)
  # 40 messages > fresh tail (32) AND > leaf fanout (8) → compactable chunk
  engine.ingest("s", (1..40).flat_map { |i| [msg(:user, "question #{i}"), msg(:assistant, "answer #{i}")] })
  before = engine.tokens("s")
  id = engine.compact_leaf("s")
  assert id
  assert engine.tokens("s") < before
  summary = engine.store.summary(id)
  assert_equal "leaf", summary["kind"]
  assert_equal 0, summary["depth"]
  assert_includes summary["content"], "summary text"

  assembled = engine.assemble("s", budget: 10_000)
  assert_includes assembled[:summary], %(<summary id="#{id}" kind="leaf" depth="0")
  assert_includes assembled[:summary], "Some earlier messages have been summarized"
  engine.close
ensure
  FileUtils.rm_rf(w)
end

test "seahorse: compact_until_under loops until the budget is met" do
  w = workspace
  engine = seahorse_engine(w)
  engine.ingest("s", (1..40).flat_map { |i| [msg(:user, "q#{i} " + "x" * 200), msg(:assistant, "a#{i} " + "y" * 200)] })
  created = engine.compact_until_under("s", 200)
  assert created.any?
  assert engine.tokens("s") <= 200
  engine.close
ensure
  FileUtils.rm_rf(w)
end

test "seahorse: grep (LIKE + wildcard + role filter + summary scope) and expand" do
  w = workspace
  engine = seahorse_engine(w)
  engine.ingest("s", [
    msg(:user, "deploy the harbor stack on friday"),
    msg(:assistant, "ack", tool_calls: [{ "id" => "t1", "name" => "exec", "arguments" => { "command" => "ls" } }]),
    msg(:tool, "file.txt", tool_call_id: "t1"),
  ])
  retrieval = Seahorse::Retrieval.new(store: engine.store, session: "s")

  out = JSON.parse(ShortGrep.new(retrieval: retrieval).call("pattern" => "harbor"))
  assert_equal 1, out["messages"].size
  assert_equal "user", out["messages"].first["role"]
  assert_includes out["messages"].first["snippet"], "harbor"

  out = JSON.parse(ShortGrep.new(retrieval: retrieval).call("pattern" => "harbor", "role" => "assistant"))
  assert_equal 0, out["messages"].size
  assert_includes out["hint"], "fuzzy"

  out = JSON.parse(ShortGrep.new(retrieval: retrieval).call("pattern" => "%stack%"))
  assert_equal 1, out["messages"].size

  msg_id = out["messages"].first["id"]
  expanded = JSON.parse(ShortExpand.new(retrieval: retrieval).call("message_ids" => [msg_id]))
  assert_equal "deploy the harbor stack on friday", expanded["messages"].first["content"]
  assert expanded["tokenCount"] > 0

  # expand of the tool message: tool_result part carries no content
  engine.ingest("s2", [msg(:user, "x"), msg(:tool, "BIG RESULT", tool_call_id: "t9")])
  r2 = Seahorse::Retrieval.new(store: engine.store, session: "s2")
  found = JSON.parse(ShortGrep.new(retrieval: r2).call("pattern" => "BIG"))
  expanded2 = JSON.parse(ShortExpand.new(retrieval: r2).call("message_ids" => [found["messages"].first["id"]]))
  part = expanded2["messages"].first["parts"].find { |p| p["type"] == "tool_result" }
  assert_equal "t9", part["toolCallId"]
  assert_nil part["text"] || part["content"]
  engine.close
ensure
  FileUtils.rm_rf(w)
end

test "seahorse middleware: assembles history, overrides summary, ingests the turn" do
  w = workspace
  engine = seahorse_engine(w)
  engine.ingest("hb", [msg(:user, "old question"), msg(:assistant, "old answer")])

  app = ->(env) { env[:messages] << msg(:assistant, "new answer"); env }
  env = env_with([msg(:user, "new question")])
  SeahorseContext.new(app, engine: engine, session: "hb", budget: 10_000, window: 100_000).call(env)

  contents = env[:messages].map(&:content)
  assert_equal ["old question", "old answer", "new question", "new answer"], contents

  # the turn's delta is now in the store
  assembled = engine.assemble("hb", budget: 10_000)
  assert_equal 4, assembled[:messages].size
  engine.close
ensure
  FileUtils.rm_rf(w)
end

puts "\n#{$count} tests, #{$failures.size} failures"
exit($failures.empty? ? 0 : 1)
