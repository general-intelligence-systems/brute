# frozen_string_literal: true

# P2 batch tests: outbox + channel five (message/send_file/send_tts/load_image/
# reaction), runtime_events, turn_profile, evolution_cold_path.

require "fileutils"
require "tmpdir"
require "json"

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "brute"

ROOT = File.expand_path("..", __dir__)
%w[fs_sandbox diff_result exec_session web_http html_markdown skill_registries web_search web_fetch
   cron_tool outbox message reaction send_file send_tts load_image read_file write_file edit_file
   append_file list_dir exec find_skills install_skill spawn subagent spawn_status tool_wrapper
   workspace_guard tool_policy].each { |f| require_relative "#{ROOT}/tools/#{f}" }
require_relative "#{ROOT}/cron"
%w[session_store memory_files skills_catalog token_estimator context_budget emergency_compression
   steering_loop state_manager cron_schedule model_router media fallback_chain subturns
   runtime_events evolution_log evolution_cold_path].each { |f| require_relative "#{ROOT}/middleware/#{f}" }

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
  Dir.mktmpdir("picoclaw-p2-test")
end

def msg(role, content = "x", **kw)
  Brute::Message.new(role: role, content: content, **kw)
end

def env_with(messages)
  { messages: messages, metadata: {}, events: [], current_iteration: 0 }
end

# --- outbox + channel five --------------------------------------------------------

test "message: outbox record, defaults, per-round tracking" do
  w = workspace
  outbox = Outbox.new(path: File.join(w, "outbound.jsonl"))
  tool = Message.new(outbox: outbox, workspace: w)
  assert_equal "Message sent.", tool.call("content" => "hello there")
  record = JSON.parse(File.readlines(File.join(w, "outbound.jsonl")).last)
  assert_equal "cli", record["channel"]
  assert_equal "direct", record["chat_id"]
  assert_equal "hello there", record["content"]
  assert outbox.sent_to?("cli", "direct")
  assert outbox.sent_in_round?
  outbox.reset_round!
  refute outbox.sent_in_round?

  assert_equal "message requires content or media", Message.new(outbox: outbox, workspace: w).call({})
  assert_equal "media attachments are not enabled (tools.message.media_enabled)",
               tool.call("media" => [{ "path" => "x.png" }])
ensure
  FileUtils.rm_rf(w)
end

test "message: media attachments validated + stored with refs in the record" do
  w = workspace
  File.binwrite(File.join(w, "doc.txt"), "content")
  store = Media::Store.new(dir: w)
  outbox = Outbox.new(path: File.join(w, "outbound.jsonl"))
  tool = Message.new(outbox: outbox, workspace: w, media_enabled: true, media_store: store)
  out = tool.call("content" => "see attached", "media" => [{ "path" => "doc.txt" }])
  assert_equal "Message sent.", out
  record = JSON.parse(File.readlines(File.join(w, "outbound.jsonl")).last)
  assert record["media"].first.start_with?("media://")

  escape = tool.call("media" => [{ "path" => "../outside" }])
  assert_includes escape, "outside the workspace"
ensure
  FileUtils.rm_rf(w)
end

test "send_file: stores media, appends outbox record, validates" do
  w = workspace
  File.binwrite(File.join(w, "report.pdf"), "pdf")
  store = Media::Store.new(dir: w)
  outbox = Outbox.new(path: File.join(w, "outbound.jsonl"))
  tool = SendFile.new(outbox: outbox, workspace: w, media_store: store)
  assert_equal "File sent: report.pdf", tool.call("path" => "report.pdf")
  record = JSON.parse(File.readlines(File.join(w, "outbound.jsonl")).last)
  assert_equal "report.pdf", record["content"]
  assert record["media"].first.start_with?("media://")
  assert_equal "path is required", tool.call({})
  assert_equal "file not found: nope.txt", tool.call("path" => "nope.txt")
ensure
  FileUtils.rm_rf(w)
end

test "send_tts: synth → media → outbox" do
  w = workspace
  store = Media::Store.new(dir: w)
  outbox = Outbox.new(path: File.join(w, "outbound.jsonl"))
  tool = SendTTS.new(outbox: outbox, synthesize: ->(text) { "AUDIO(#{text})" },
                     media_store: store, media_dir: w)
  assert_equal "Audio sent: hi.ogg", tool.call("text" => "hi", "filename" => "hi.ogg")
  assert_equal "AUDIO(hi)", File.binread(File.join(w, "hi.ogg"))
  record = JSON.parse(File.readlines(File.join(w, "outbound.jsonl")).last)
  assert record["media"].first.start_with?("media://")
  assert_equal "text is required", tool.call({})
ensure
  FileUtils.rm_rf(w)
end

test "load_image: magic-byte validation + media ref; resolver rewrites to path tag next pass" do
  w = workspace
  File.binwrite(File.join(w, "a.png"), "\x89PNG\r\n\x1A\n".b + "data")
  File.binwrite(File.join(w, "a.txt"), "text")
  store = Media::Store.new(dir: w)
  tool = LoadImage.new(workspace: w, media_store: store)
  out = tool.call("path" => "a.png")
  assert_includes out, "Image loaded: media://"
  ref = out[/media:\/\/[0-9a-f-]+/]

  assert_includes tool.call("path" => "a.txt"), "not a supported image"
  assert_equal "path is required", tool.call({})

  env = env_with([msg(:tool, out)])
  Media.new(->(e) { e }, store: store).call(env)
  assert_includes env[:messages].last.content, "[image:#{File.join(w, "a.png")}]"
ensure
  FileUtils.rm_rf(w)
end

test "reaction: errors without a capable channel (upstream parity)" do
  assert_equal "channel cli does not support reactions", Reaction.new.call("message_id" => "1")
end

# --- runtime_events ------------------------------------------------------------------

test "runtime_events: turn span emission, include filter, min severity" do
  logged = []
  logger = ->(line) { logged << line }
  env = env_with([msg(:user, "hi")])
  RuntimeEvents.new(->(e) { e }, include: ["agent.*"], logger: logger).call(env)
  kinds = env[:events].map { |e| e["kind"] }
  assert_equal %w[agent.turn.start agent.turn.end], kinds
  assert_equal 2, logged.size

  env2 = env_with([msg(:user, "hi")])
  RuntimeEvents.new(->(e) { e }, include: ["agent.turn.end"], logger: logger).call(env2)
  assert_equal 3, logged.size # only turn.end logged
ensure
  RuntimeEvents.current = nil
end

# --- evolution_cold_path -----------------------------------------------------------------

test "evolution_cold_path: cluster, merge patterns, draft, apply" do
  w = workspace
  dir = File.join(w, ".evolution")
  FileUtils.mkdir_p(dir)
  records = [
    { id: "t1", kind: "task", summary: "check disk usage", success: true },
    { id: "t2", kind: "task", summary: "Check disk usage!", success: true },
    { id: "t3", kind: "task", summary: "check  disk   usage", success: true },
    { id: "t4", kind: "task", summary: "unrelated thing", success: false },
  ]
  File.write(File.join(dir, "records.jsonl"), records.map { |r| JSON.generate(r) }.join("\n") + "\n")

  # draft mode: pattern written, skill drafted to skill-drafts.json
  app = ->(env) { env }
  EvolutionColdPath.new(app, dir: dir, mode: "draft", min_task_count: 2,
                            skills_dir: File.join(w, "skills"),
                            generate_draft: ->(_prompt) { "# Do the disk checks\n\nRun df -h regularly." * 3 })
    .call(env_with([msg(:user, "hb")]))
  patterns = JSON.parse(File.read(File.join(dir, "pattern-records.jsonl")))
  assert_equal 1, patterns.size
  assert_equal "check-disk-usage", patterns.first["label"]
  assert_equal "ready", patterns.first["status"]
  assert_equal 3, patterns.first["task_record_ids"].size
  drafts = JSON.parse(File.read(File.join(dir, "skill-drafts.json")))
  assert_equal "check-disk-usage", drafts.first["name"]
  assert_equal "candidate", drafts.first["review"]

  # apply mode: writes the skill with frontmatter
  EvolutionColdPath.new(app, dir: dir, mode: "apply", min_task_count: 2,
                            skills_dir: File.join(w, "skills"),
                            generate_draft: ->(_p) { "# Body\n\nDo checks." * 4 })
    .call(env_with([msg(:user, "hb")]))
  skill = File.read(File.join(w, "skills", "check-disk-usage", "SKILL.md"))
  assert_includes skill, "name: check-disk-usage"
  assert_includes skill, "# Body"
ensure
  FileUtils.rm_rf(w)
end

test "evolution_cold_path: observe mode does nothing" do
  w = workspace
  dir = File.join(w, ".evolution")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "records.jsonl"), JSON.generate({ id: "t1", kind: "task", summary: "x", success: true }) + "\n")
  EvolutionColdPath.new(->(env) { env }, dir: dir, mode: "observe").call(env_with([msg(:user, "hb")]))
  refute File.exist?(File.join(dir, "pattern-records.jsonl"))
ensure
  FileUtils.rm_rf(w)
end

# --- main.rb wiring ----------------------------------------------------------------

test "main.rb: stack builds with P2 wiring; the channel five are registered" do
  ENV["OPENROUTER_API_KEY"] ||= "dummy"
  load "#{ROOT}/main.rb"
  config = load_config
  build_agent(config)
  tools = Brute.tools(build_tools(config, cron_store: CronStore.new(File.join(Dir.pwd, "cron", "jobs.json")))).keys.map(&:to_s)
  %w[message send_file load_image reaction].each { |name| assert_includes tools, name }
  refute tools.include?("send_tts") # no TTS model configured → unregistered (upstream DetectTTS)
end

puts "\n#{$count} tests, #{$failures.size} failures"
exit($failures.empty? ? 0 : 1)
