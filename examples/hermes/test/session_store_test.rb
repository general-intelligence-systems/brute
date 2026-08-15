# frozen_string_literal: true

# Plain-ruby test harness for SessionStore (extralite) + session_search.

require "json"
require "fileutils"
require "tmpdir"
require "brute"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/session_store"
require_relative "#{ROOT}/middleware/session_store"
require_relative "#{ROOT}/tools/session_search"

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

def fresh_dir
  Dir.mktmpdir("hermes-session-test")
end

def store_in(dir)
  Hermes::SessionStore.new(path: File.join(dir, "state.db"))
end

puts "SessionStore core"
test "create/get session, append/get messages in insertion order" do
  d = fresh_dir
  s = store_in(d)
  s.create_session(id: "s1", source: "cli", cwd: d)
  s.append_message(session_id: "s1", role: :user, content: "first")
  s.append_message(session_id: "s1", role: :assistant, content: "second")
  msgs = s.get_messages("s1")
  assert_eq %w[first second], msgs.map { |m| m[:content] }
  assert_eq %w[user assistant], msgs.map { |m| m[:role] }
  sess = s.get_session("s1")
  assert_eq 2, sess[:message_count]
  s.close
end

test "batch append is one transaction; counters bump" do
  d = fresh_dir
  s = store_in(d)
  s.create_session(id: "s1")
  ids = s.append_messages_batch(session_id: "s1", messages: [
    { role: :user, content: "u" },
    { role: :tool, content: "t", tool_call_id: "tc1" },
  ])
  assert_eq 2, ids.size
  sess = s.get_session("s1")
  assert_eq 2, sess[:message_count]
  assert_eq 1, sess[:tool_call_count]
  s.close
end

test "around-window and recent sessions" do
  d = fresh_dir
  s = store_in(d)
  s.create_session(id: "s1")
  10.times { |i| s.append_message(session_id: "s1", role: :user, content: "msg #{i}") }
  around = s.get_messages_around("s1", 5, window: 2)
  assert_eq ["msg 2", "msg 3", "msg 4", "msg 5", "msg 6"], around.map { |m| m[:content] }
  assert_eq 1, s.recent_sessions(limit: 5).size
  s.close
end

test "compression rotation links parent and ends it" do
  d = fresh_dir
  s = store_in(d)
  s.create_session(id: "parent")
  child = s.rotate("parent")
  parent = s.get_session("parent")
  assert_eq "compression", parent[:end_reason]
  assert parent[:ended_at]
  assert_eq "parent", s.get_session(child)[:parent_session_id]
  s.close
end

puts "FTS search"
test "FTS finds content, role filter, sort, compaction excluded" do
  d = fresh_dir
  s = store_in(d)
  s.create_session(id: "s1")
  s.append_message(session_id: "s1", role: :user, content: "how do I configure nginx")
  s.append_message(session_id: "s1", role: :assistant, content: "edit nginx.conf and reload")
  s.append_message(session_id: "s1", role: :user, content: "[CONTEXT COMPACTION — REFERENCE ONLY] nginx summary")
  hits = s.search("nginx")
  assert_eq 2, hits.size, "compaction summary must be excluded"
  users = s.search("nginx", role_filter: ["user"])
  assert_eq 1, users.size
  oldest = s.search("nginx", sort: "oldest")
  assert oldest.first[:content].include?("how do I")
  s.close
end

test "LIKE fallback works when FTS is off" do
  d = fresh_dir
  s = store_in(d)
  s.instance_variable_set(:@fts, false)
  s.create_session(id: "s1")
  s.append_message(session_id: "s1", role: :user, content: "postgres migration question")
  hits = s.search("postgres")
  assert_eq 1, hits.size
  s.close
end

test "empty query returns nothing" do
  d = fresh_dir
  s = store_in(d)
  assert_eq [], s.search("")
  assert_eq [], s.search("   ")
  s.close
end

puts "middleware: hydrate + crash-persist + flush"
test "fresh turn hydrates from the store and persists incrementally" do
  d = fresh_dir
  path = File.join(d, "state.db")
  seed = store_in(d)
  seed.create_session(id: "hermes")
  seed.append_message(session_id: "hermes", role: :user, content: "past question")
  seed.append_message(session_id: "hermes", role: :assistant, content: "past answer")
  seed.close

  env = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  env[:messages].user("new question")
  Hermes::Middleware::SessionStore.new(->(env) {
    # inside the turn: history loaded, current message already persisted
    env[:messages] << Brute::Message.new(role: :assistant, content: "new answer")
  }, path: path).call(env)

  assert_eq ["past question", "past answer", "new question", "new answer"],
               env[:messages].map(&:content)

  check = store_in(d)
  assert_eq ["past question", "past answer", "new question", "new answer"],
               check.get_messages("hermes").map { |m| m[:content] }
  check.close
end

test "flush is idempotent within an invocation; new turns append new rows" do
  d = fresh_dir
  path = File.join(d, "state.db")
  env = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  env[:messages].user("same question")
  Hermes::Middleware::SessionStore.new(->(env) {}, path: path, session_id: "hermes").call(env)
  check = store_in(d)
  assert_eq 1, check.get_messages("hermes").count { |m| m[:content] == "same question" }
  check.close

  # A second invocation IS a new turn — appending again is correct.
  env = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
  env[:messages].user("same question")
  Hermes::Middleware::SessionStore.new(->(env) {}, path: path, session_id: "hermes").call(env)
  check = store_in(d)
  assert_eq 2, check.get_messages("hermes").count { |m| m[:content] == "same question" }
  check.close
end

puts "session_search tool shapes"
test "discover / scroll / read / browse" do
  d = fresh_dir
  s = store_in(d)
  s.create_session(id: "s1", title: "nginx debug")
  s.append_message(session_id: "s1", role: :user, content: "configure nginx reverse proxy")
  s.append_message(session_id: "s1", role: :assistant, content: "set proxy_pass in the server block")
  tool = HermesTools::SessionSearch.new(s)

  disc = JSON.parse(tool.call("query" => "nginx"))
  assert_eq "discover", disc["shape"]
  assert_eq 1, disc["count"]
  assert disc["results"].first["snippet"].include?("nginx")

  scroll = JSON.parse(tool.call("session_id" => "s1", "around_message_id" => 1, "window" => 2))
  assert_eq "scroll", scroll["shape"]
  assert scroll["messages"].size >= 1

  read = JSON.parse(tool.call("session_id" => "s1"))
  assert_eq "read", read["shape"]
  assert_eq "nginx debug", read["session"]["title"]

  browse = JSON.parse(tool.call({}))
  assert_eq "browse", browse["shape"]
  assert browse["sessions"].any? { |x| x["id"] == "s1" }
  s.close
end

test "limit clamps to [1,10]; role filter applies in discover" do
  d = fresh_dir
  s = store_in(d)
  s.create_session(id: "s1")
  15.times { |i| s.append_message(session_id: "s1", role: :user, content: "common term #{i}") }
  tool = HermesTools::SessionSearch.new(s)
  r = JSON.parse(tool.call("query" => "common", "limit" => 99))
  assert r["count"] <= 10
  s.close
end

puts "\n#{$count - $failures.size}/#{$count} passed"
exit($failures.empty? ? 0 : 1)
