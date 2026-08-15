# frozen_string_literal: true

# Plain-ruby test harness for the P0 milestone: web_fetch, web_search, cron
# (store/tool/middleware), and the middleware batch (session_store,
# memory_files, skills_catalog, context_budget, compaction, steering,
# state_manager). Runs anywhere, no gems beyond brute + fugit.

require "fileutils"
require "tmpdir"
require "json"
require "socket"

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "brute"

ROOT = File.expand_path("..", __dir__)
%w[fs_sandbox diff_result exec_session web_http html_markdown web_search web_fetch cron_tool
   read_file write_file edit_file append_file list_dir exec].each { |f| require_relative "#{ROOT}/tools/#{f}" }
require_relative "#{ROOT}/cron"
%w[session_store memory_files skills_catalog token_estimator context_budget compaction
   steering_loop state_manager cron_schedule emergency_compression].each { |f| require_relative "#{ROOT}/middleware/#{f}" }

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

def refute_includes(hay, needle)
  raise("expected NOT to include #{needle.inspect}:\n#{hay}") if hay.include?(needle)
end

def refute(cond, msg = "expected falsy")
  raise msg if cond
end

def assert_nil(val)
  raise("expected nil, got #{val.inspect}") unless val.nil?
end

def assert_raises(klass)
  yield
  raise("expected #{klass} to be raised, nothing was")
rescue klass => e
  e
end

def workspace
  Dir.mktmpdir("picoclaw-p0-test")
end

def msg(role, content = "x", **kw)
  Brute::Message.new(role: role, content: content, **kw)
end

def env_with(messages)
  { messages: messages, metadata: {}, events: [], current_iteration: 0 }
end

# A minimal HTTP/1.1 stub: path → [status, headers, body] (or a proc).
class HttpStub
  attr_reader :requests

  def initialize(routes)
    @routes = routes
    @requests = []
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new { loop { accept_once } }
  end

  def port = @port

  def accept_once
    sock = @server.accept
    request_line = sock.gets
    return sock.close unless request_line

    headers = {}
    while (line = sock.gets) && line != "\r\n"
      k, v = line.split(": ", 2)
      headers[k.downcase] = v.to_s.strip
    end
    @requests << [request_line.strip, headers]
    path = request_line.split(" ")[1]
    route = @routes[path] || @routes[:default]
    status, extra, body = route.is_a?(Proc) ? route.call(headers) : route
    body = body.to_s
    sock.write "HTTP/1.1 #{status}\r\ncontent-length: #{body.bytesize}\r\nconnection: close\r\n#{extra.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n#{body}"
    sock.close
  rescue StandardError
    sock.close rescue nil
  end

  def stop
    @thread.kill
    @server.close
  end
end

# --- web_fetch -----------------------------------------------------------------

test "web_fetch: JSON pretty-printed, HTML text extraction, raw passthrough" do
  stub = HttpStub.new(
    "/data.json" => [200, { "content-type" => "application/json" }, '{"b":1,"a":{"z":2,"y":3}}'],
    "/page" => [200, { "content-type" => "text/html" }, "<html><head><style>x{}</style></head><body><h1>Title</h1><script>evil()</script><p>Hello <b>world</b></p></body></html>"],
    "/blob" => [200, { "content-type" => "application/octet-stream" }, "rawbytes"],
  )
  tool = WebFetch.new(allow_private: true)
  json = JSON.parse(tool.call("url" => "http://127.0.0.1:#{stub.port}/data.json"))
  assert_equal "json", json["extractor"]
  assert(json["text"].index('"a"') < json["text"].index('"b"'), "keys should be sorted like Go's marshal")
  assert_equal 200, json["status"]
  assert_equal false, json["truncated"]

  html = JSON.parse(tool.call("url" => "http://127.0.0.1:#{stub.port}/page"))
  assert_equal "text", html["extractor"]
  assert_includes html["text"], "Title"
  assert_includes html["text"], "Hello world"
  refute_includes html["text"], "evil"

  raw = JSON.parse(tool.call("url" => "http://127.0.0.1:#{stub.port}/blob"))
  assert_equal "raw", raw["extractor"]
  assert_equal "rawbytes", raw["text"]
ensure
  stub&.stop
end

test "web_fetch: markdown format, truncation, guards, redirect cap" do
  stub = HttpStub.new(
    "/md" => [200, { "content-type" => "text/html" }, "<h1>Head</h1><p>para</p><ul><li>one</li><li>two</li></ul><a href=\"https://x.example\">link</a>"],
    "/big" => [200, { "content-type" => "text/plain" }, "x" * 6000],
    "/loop" => [302, { "location" => "/loop" }, ""],
    "/hop" => [302, { "location" => "/final" }, ""],
    "/final" => [200, { "content-type" => "text/plain" }, "landed"],
  )
  md = JSON.parse(WebFetch.new(allow_private: true, format: "markdown").call("url" => "http://127.0.0.1:#{stub.port}/md"))
  assert_equal "markdown", md["extractor"]
  assert_includes md["text"], "# Head"
  assert_includes md["text"], "- one"
  assert_includes md["text"], "[link](https://x.example)"

  tool = WebFetch.new(allow_private: true, max_chars: 5000)
  big = JSON.parse(tool.call("url" => "http://127.0.0.1:#{stub.port}/big"))
  assert_equal true, big["truncated"]
  assert_includes big["text"], "[Content truncated due to size limit]"

  small = JSON.parse(tool.call("url" => "http://127.0.0.1:#{stub.port}/big", "maxChars" => 500))
  assert_equal 500 + "\n[Content truncated due to size limit]".length, small["length"]

  assert_equal "stopped after 5 redirects", tool.call("url" => "http://127.0.0.1:#{stub.port}/loop")
  assert_includes tool.call("url" => "http://127.0.0.1:#{stub.port}/hop"), "landed"

  assert_equal "only http/https URLs are allowed", tool.call("url" => "ftp://x.example/f")
  assert_equal "missing domain in URL", tool.call("url" => "http:///path")
  assert_equal "url is required", tool.call({})
  assert_equal "fetching private or local network hosts is not allowed",
               WebFetch.new.call("url" => "http://127.0.0.1:#{stub.port}/md")
ensure
  stub&.stop
end

test "web_fetch: Cloudflare challenge retried once with honest UA" do
  calls = []
  stub = HttpStub.new(
    "/cf" => lambda { |headers|
      calls << headers["user-agent"]
      calls.size == 1 ? [403, { "cf-mitigated" => "challenge" }, "denied"] : [200, { "content-type" => "text/plain" }, "allowed"]
    },
  )
  out = JSON.parse(WebFetch.new(allow_private: true).call("url" => "http://127.0.0.1:#{stub.port}/cf"))
  assert_equal "allowed", out["text"]
  assert_equal 2, calls.size
  assert_includes calls[1], "picoclaw/"
ensure
  stub&.stop
end

# --- web_search ------------------------------------------------------------------

test "web_search: provider resolution order and script heuristic" do
  assert_equal "sogou", WebSearch.resolve_provider_name({}, "anything") # sogou default-enabled
  refute WebSearch.registerable?({ "sogou" => { "enabled" => false } })
  assert WebSearch.registerable?({ "sogou" => { "enabled" => false }, "duckduckgo" => { "enabled" => true } })

  both = { "duckduckgo" => { "enabled" => true } }
  assert_equal "duckduckgo", WebSearch.resolve_provider_name(both, "hello world")
  assert_equal "sogou", WebSearch.resolve_provider_name(both, "你好")

  brave = { "brave" => { "enabled" => true, "api_keys" => ["k1"] } }
  assert_equal "brave", WebSearch.resolve_provider_name(brave, "x")
  explicit = brave.merge("provider" => "duckduckgo") # not enabled → falls through to auto
  assert_equal "brave", WebSearch.resolve_provider_name(explicit, "x")
  explicit_ready = brave.merge("provider" => "brave")
  assert_equal "brave", WebSearch.resolve_provider_name(explicit_ready, "x")
  unknown_provider = { "provider" => "defunct", "sogou" => { "enabled" => true } }
  assert_equal "sogou", WebSearch.resolve_provider_name(unknown_provider, "x") # stale config → auto
end

test "web_search: args validation + count clamp" do
  tool = WebSearch.new(options: {})
  assert_equal "query is required", tool.call({})
  assert_equal "range must be a string", tool.call("query" => "x", "range" => 5)
  assert_equal "range must be one of: d, w, m, y", tool.call("query" => "x", "range" => "fortnight")
end

test "web_search: duckduckgo extraction via stubbed HTTP" do
  html = <<~HTML
    <a class="result__a" href="https://a.example/">Title A</a>
    <a class="result__snippet">Snippet A</a>
    <a class="result__a" href="/l/?uddg=https%3A%2F%2Fb.example%2F">Title B</a>
    <a class="result__snippet">Snippet B</a>
  HTML
  WebHttp.define_singleton_method(:plain_get) { |*_args, **_kw| [Struct.new(:code).new("200"), html] }
  out = WebSearch.new(options: { "provider" => "duckduckgo", "duckduckgo" => { "enabled" => true } })
                 .call("query" => "test", "count" => 2)
  assert_includes out, "Results for: test (via DuckDuckGo)"
  assert_includes out, "1. Title A\n   https://a.example/\n   Snippet A"
  assert_includes out, "https://b.example/" # uddg-decoded
ensure
  WebHttp.singleton_class.send(:remove_method, :plain_get)
  load File.expand_path("#{ROOT}/tools/web_http.rb", __dir__)
end

test "web_search: brave key rotation on 429" do
  calls = []
  WebHttp.define_singleton_method(:plain_get) do |url, headers:, **_kw|
    calls << headers["X-Subscription-Token"]
    code = calls.size == 1 ? "429" : "200"
    body = { "web" => { "results" => [{ "title" => "T", "url" => "https://r.example", "description" => "D" }] } }.to_json
    [Struct.new(:code).new(code), body]
  end
  out = WebSearch.new(options: { "brave" => { "enabled" => true, "api_keys" => %w[k1 k2] } })
                 .call("query" => "q")
  assert_equal %w[k1 k2], calls
  assert_includes out, "1. T\n   https://r.example\n   D"
ensure
  WebHttp.singleton_class.send(:remove_method, :plain_get)
  load File.expand_path("#{ROOT}/tools/web_http.rb", __dir__)
end

# --- cron ---------------------------------------------------------------------------

test "cron tool: add semantics (at_seconds/every_seconds/cron_expr, priority, name truncation)" do
  w = workspace
  store = CronStore.new(File.join(w, "cron", "jobs.json")).load
  tool = CronTool.new(store: store)
  assert_equal "message is required for add", tool.call("action" => "add")
  assert_equal "one of at_seconds, every_seconds, or cron_expr is required",
               tool.call("action" => "add", "message" => "m")

  out = tool.call("action" => "add", "message" => "short reminder", "at_seconds" => 600)
  assert_includes out, "Cron job added: short reminder (id: "
  job = store.jobs.first
  assert_equal "at", job[:schedule][:kind]
  assert_equal true, job[:delete_after_run]
  assert job[:schedule][:at] > Time.now.to_i + 500

  long = tool.call("action" => "add", "message" => "x" * 40, "every_seconds" => 3600)
  assert_includes long, "Cron job added: #{"x" * 30}... (id: "
  assert_equal "every", store.jobs.last[:schedule][:kind]
  assert_equal 3600, store.jobs.last[:schedule][:every_seconds]

  # priority: at > every > expr
  tool.call("action" => "add", "message" => "prio", "at_seconds" => 60, "every_seconds" => 60, "cron_expr" => "0 9 * * *")
  assert_equal "at", store.jobs.last[:schedule][:kind]
  tool.call("action" => "add", "message" => "prio2", "every_seconds" => 60, "cron_expr" => "0 9 * * *")
  assert_equal "every", store.jobs.last[:schedule][:kind]
  # zero values count as absent
  tool.call("action" => "add", "message" => "expr only", "at_seconds" => 0, "cron_expr" => "0 9 * * *")
  assert_equal "cron", store.jobs.last[:schedule][:kind]
ensure
  FileUtils.rm_rf(w)
end

test "cron tool: command gating" do
  w = workspace
  store = CronStore.new(File.join(w, "cron", "jobs.json")).load
  strict = CronTool.new(store: store, allow_command: false)
  assert_equal "command_confirm=true is required when allow_command is disabled",
               strict.call("action" => "add", "message" => "m", "every_seconds" => 60, "command" => "df -h")
  assert_includes strict.call("action" => "add", "message" => "m", "every_seconds" => 60,
                              "command" => "df -h", "command_confirm" => true), "Cron job added:"
  no_exec = CronTool.new(store: store, exec_enabled: false)
  assert_equal "command execution is disabled",
               no_exec.call("action" => "add", "message" => "m", "every_seconds" => 60, "command" => "df -h")
  assert_equal "df -h", store.jobs.first[:payload][:command]
ensure
  FileUtils.rm_rf(w)
end

test "cron tool: list/get/update/remove/enable/disable" do
  w = workspace
  store = CronStore.new(File.join(w, "cron", "jobs.json")).load
  tool = CronTool.new(store: store)
  assert_equal "No scheduled jobs", tool.call("action" => "list")

  tool.call("action" => "add", "message" => "hourly thing", "every_seconds" => 3600)
  id = store.jobs.first[:id]
  assert_includes tool.call("action" => "list"), "- hourly thing (id: #{id}, every 3600s)"
  assert_includes tool.call("action" => "get", "job_id" => id), %("message":"hourly thing")
  assert_equal "Job nope not found", tool.call("action" => "get", "job_id" => "nope")

  assert_equal "at least one update field is required", tool.call("action" => "update", "job_id" => id)
  updated = tool.call("action" => "update", "job_id" => id, "name" => "renamed", "every_seconds" => 7200, "command" => "uptime")
  assert_includes updated, "Cron job updated:"
  assert_equal "renamed", store.jobs.first[:name]
  assert_equal 7200, store.jobs.first[:schedule][:every_seconds]
  assert_equal "uptime", store.jobs.first[:payload][:command]
  # empty command clears it
  tool.call("action" => "update", "job_id" => id, "command" => "")
  assert_equal "", store.jobs.first[:payload][:command]

  assert_equal "Cron job '#{store.jobs.first[:name]}' disabled", tool.call("action" => "disable", "job_id" => id)
  assert_nil store.jobs.first[:state][:next_run_at]
  assert_equal "Cron job '#{store.jobs.first[:name]}' enabled", tool.call("action" => "enable", "job_id" => id)
  assert store.jobs.first[:state][:next_run_at].to_i > Time.now.to_i

  assert_equal "Cron job removed: #{id}", tool.call("action" => "remove", "job_id" => id)
  assert_equal [], store.jobs
ensure
  FileUtils.rm_rf(w)
end

test "cron middleware: message job injection, command job execution, one-shot deletion, persistence" do
  w = workspace
  path = File.join(w, "cron", "jobs.json")
  store = CronStore.new(path)
  store.add(name: "msg job", schedule: { kind: "every", every_seconds: 3600 }, message: "do the thing")
  store.add(name: "cmd job", schedule: { kind: "at", at: Time.now.to_i + 3600 }, message: "m", command: "echo cron-ran")
  store.jobs.each { |j| j[:state][:next_run_at] = Time.now.to_i - 1 } # force both due
  store.save

  exec_tool = Exec.new(workspace: w)
  app = ->(env) { env }
  env = env_with([msg(:user, "heartbeat")])
  CronSchedule.new(app, store: store, exec_tool: exec_tool).call(env)

  injected = env[:messages].last.content
  assert_includes injected, "msg job: do the thing"
  assert_includes injected, "cmd job: Scheduled command 'echo cron-ran' executed:\ncron-ran"

  saved = JSON.parse(File.read(path), symbolize_names: true)[:jobs]
  assert_equal 1, saved.size # one-shot deleted
  assert_equal "msg job", saved.first[:name]
  assert_equal "ok", saved.first[:state][:last_status]
  assert saved.first[:state][:next_run_at] > Time.now.to_i # rescheduled
ensure
  FileUtils.rm_rf(w)
end

# --- session_store -----------------------------------------------------------------

test "session_store: sanitize-on-load (system, orphans, incomplete tool blocks)" do
  w = workspace
  path = File.join(w, "sessions", "s.jsonl")
  FileUtils.mkdir_p(File.dirname(path))
  calls = [{ "id" => "tc1", "name" => "read_file", "arguments" => { "path" => "x" } }]
  lines = [
    msg(:system, "old system"),
    msg(:tool, "orphan result", tool_call_id: "tc0"),
    msg(:user, "u1"),
    msg(:assistant, "", tool_calls: calls),
    msg(:tool, "ok", tool_call_id: "tc1"),
    msg(:assistant, "", tool_calls: [{ "id" => "tcX", "name" => "exec", "arguments" => {} }]), # no result follows
    msg(:assistant, "final answer"),
  ]
  File.write(path, lines.map { |m| JSON.generate(m.to_h) }.join("\n") + "\n")

  env = env_with([msg(:user, "current")])
  SessionStore.new(->(e) { e }, path: path).call(env)

  roles = env[:messages].map { |m| m.role.to_sym }
  assert_equal %i[user assistant tool assistant user], roles
  assert_equal 5, env[:messages].size
  assert_equal "u1", env[:messages].first.content
  assert_equal "current", env[:messages].last.content

  persisted = File.readlines(path).map { |l| JSON.parse(l) }
  refute persisted.any? { |m| m["role"] == "system" }
ensure
  FileUtils.rm_rf(w)
end

test "session_store: restore point + rollback" do
  w = workspace
  path = File.join(w, "sessions", "s.jsonl")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.generate(msg(:user, "old").to_h) + "\n")

  app = lambda do |env|
    env[:messages] << msg(:assistant, "progress")
    env[:messages] << msg(:user, "more")
    env
  end
  env = env_with([msg(:user, "new")])
  middleware = SessionStore.new(app, path: path)
  middleware.call(env)
  assert_equal 4, env[:messages].size

  SessionStore.rollback!(env)
  assert_equal 2, env[:messages].size # old + new only
  assert_equal "new", env[:messages].last.content
ensure
  FileUtils.rm_rf(w)
end

# --- memory_files --------------------------------------------------------------------

test "memory_files: prompt part assembly + daily notes" do
  w = workspace
  store = MemoryFiles::Store.new(File.join(w, "memory"))
  assert_equal "", store.prompt_part

  store.write_long_term("user prefers tea")
  assert_equal "## Long-term Memory\n\nuser prefers tea", store.prompt_part

  store.append_today("did task A")
  today = store.read_today
  assert_includes today, "# #{Time.now.strftime("%Y-%m-%d")}"
  assert_includes today, "did task A"
  store.append_today("did task B")
  assert_includes store.read_today, "did task A\ndid task B"

  part = store.prompt_part
  assert_includes part, "## Long-term Memory\n\nuser prefers tea"
  assert_includes part, "\n\n---\n\n## Recent Daily Notes\n\n"

  yesterday = Time.now - 86_400
  ypath = File.join(w, "memory", yesterday.strftime("%Y%m"), "#{yesterday.strftime("%Y%m%d")}.md")
  FileUtils.mkdir_p(File.dirname(ypath))
  File.write(ypath, "yesterday note")
  notes = store.recent_daily_notes(3)
  assert_includes notes, "---\n\nyesterday note" # newest day first, "---" between days

  env = env_with([msg(:user, "hi")])
  MemoryFiles.new(->(e) { e }, dir: File.join(w, "memory")).call(env)
  assert_equal store.prompt_part, env[:metadata][:memory_part] # computed at the same file state
ensure
  FileUtils.rm_rf(w)
end

# --- skills_catalog ------------------------------------------------------------------

test "skills_catalog: discovery priority, validation, XML catalog, active skills" do
  w = workspace
  FileUtils.mkdir_p("#{w}/skills/tour")
  File.write("#{w}/skills/tour/SKILL.md", "---\nname: tour\ndescription: Workspace tour\n---\n\n# Tour\n\nBody text.")
  FileUtils.mkdir_p("#{w}/.brute/skills/tour")
  File.write("#{w}/.brute/skills/tour/SKILL.md", "---\nname: tour\ndescription: builtin copy\n---\n\nBuiltin.")
  FileUtils.mkdir_p("#{w}/.brute/skills/plain")
  File.write("#{w}/.brute/skills/plain/SKILL.md", "# plain\n\nFirst paragraph here.\n\nMore.")
  FileUtils.mkdir_p("#{w}/.brute/skills/bad name")
  File.write("#{w}/.brute/skills/bad name/SKILL.md", "---\nname: bad name\ndescription: x\n---\n")

  catalog = SkillsCatalog.new(->(e) { e }, workspace: w,
                              roots: [File.join(w, "skills"), File.join(w, "no-global"), File.join(w, ".brute", "skills")])
  skills = catalog.discover
  assert_equal %w[plain tour], skills.map(&:name).sort
  assert_equal "workspace", skills.find { |s| s.name == "tour" }.source # first-wins over builtin
  assert_equal "First paragraph here.", skills.find { |s| s.name == "plain" }.description

  part = catalog.prompt_part
  assert_includes part, "# Skills"
  assert_includes part, "read its SKILL.md file using the read_file tool"
  assert_includes part, "<skills>\n  <skill>\n    <name>tour</name>"
  assert_includes part, "<description>Workspace tour</description>"
  assert_includes part, "<source>workspace</source>"
  refute_includes part, "Body text" # bodies not inlined

  File.write("#{w}/AGENTS.md", "---\nskills:\n  - tour\n---\n\nAgent body.")
  active = catalog.prompt_part
  assert_includes active, "# Active Skills"
  assert_includes active, "### Skill: tour\n\n# Tour\n\nBody text."
ensure
  FileUtils.rm_rf(w)
end

# --- context_budget --------------------------------------------------------------------

test "context_budget: under budget untouched; over budget force-compresses + trims, keeps system" do
  w = workspace
  summary = File.join(w, "sessions", "s.summary.md")
  messages = [msg(:system, "S")] + 6.times.flat_map { |i| [msg(:user, "u#{i} " + "x" * 400), msg(:assistant, "a#{i}")] }

  under = messages.map(&:dup)
  ContextBudget.new(->(e) { e }, tool_defs: [], max_tokens: 100, context_window: 200_000, summary_path: summary).call(env_with(under))
  assert_equal messages.size, under.size
  refute File.exist?(summary)

  over = messages.map(&:dup)
  env = env_with(over)
  ContextBudget.new(->(e) { e }, tool_defs: [], max_tokens: 100, context_window: 200, summary_path: summary).call(env)
  assert_equal :system, env[:messages].first.role.to_sym
  assert env[:messages].size < messages.size
  assert_includes File.read(summary), "Emergency compression dropped"
  assert_equal "a5", env[:messages].last.content
ensure
  FileUtils.rm_rf(w)
end

# --- compaction -------------------------------------------------------------------------

test "compaction: count trigger, keep-last-4, sidecar write, fallback truncation, split-merge" do
  w = workspace
  summary = File.join(w, "s.summary.md")

  small = [msg(:user, "u1"), msg(:assistant, "a1")]
  Compaction.new(->(e) { e }, threshold: 20, summary_path: summary, summarize: ->(_) { "S" }).call(env_with(small))
  assert_equal 2, small.size
  refute File.exist?(summary)

  messages = 6.times.flat_map { |i| [msg(:user, "u#{i}"), msg(:assistant, "a#{i}")] } # 12 msgs
  Compaction.new(->(e) { e }, threshold: 4, summary_path: summary, summarize: ->(_) { "SUMMARY TEXT" }).call(env_with(messages))
  assert_equal 4, messages.size
  assert_equal "SUMMARY TEXT", File.read(summary)

  messages = 6.times.flat_map { |i| [msg(:user, "user#{i}"), msg(:assistant, "assistant#{i}")] }
  File.write(summary, "SUMMARY TEXT")
  Compaction.new(->(e) { e }, threshold: 4, summary_path: summary, summarize: ->(_) { raise "LLM down" }).call(env_with(messages))
  assert_equal 4, messages.size
  fallback = File.read(summary)
  assert_includes fallback, "Conversation summary:"
  assert_includes fallback, "user: user0"

  prompts = []
  big = 14.times.flat_map { |i| [msg(:user, "u#{i}"), msg(:assistant, "a#{i}")] }
  Compaction.new(->(e) { e }, threshold: 4, summary_path: summary,
                 summarize: ->(p) { prompts << p; "out" }).call(env_with(big))
  assert_equal 3, prompts.size # two batches + merge
  assert_includes prompts[2], "Merge these two conversation summaries"

  token_trigger = (1..4).flat_map { |i| [msg(:user, "u#{i} " + "x" * 500), msg(:assistant, "a")] }
  Compaction.new(->(e) { e }, threshold: 1000, summary_path: summary, context_window: 1000,
                 summarize: ->(_) { "TOK" }).call(env_with(token_trigger))
  assert_equal "TOK", File.read(summary)
ensure
  FileUtils.rm_rf(w)
end

# --- steering_loop -----------------------------------------------------------------------

test "steering_loop: one-at-a-time vs all modes" do
  w = workspace
  queue = File.join(w, "steer.jsonl")
  File.write(queue, "one\ntwo\nthree\n")

  app = ->(env) { env[:messages] << msg(:assistant, "reply"); env }
  env = env_with([msg(:user, "start")])
  SteeringLoop.new(app, queue: queue, mode: "one-at-a-time",
                   interrupt_file: File.join(w, "interrupt"), abort_file: File.join(w, "abort")).call(env)
  steering = env[:messages].select { |m| m.role.to_sym == :user }.map(&:content)
  assert_equal %w[start one two three], steering
  assert_equal "", File.read(queue)

  File.write(queue, (1..12).map { |i| "m#{i}" }.join("\n") + "\n")
  env = env_with([msg(:user, "start")])
  SteeringLoop.new(app, queue: queue, mode: "all",
                   interrupt_file: File.join(w, "interrupt"), abort_file: File.join(w, "abort")).call(env)
  drained = env[:messages].select { |m| m.role.to_sym == :user }.map(&:content)
  assert_equal ["start"] + (1..12).map { |i| "m#{i}" }, drained # caps at 10 per poll, drains across passes
  assert_equal "", File.read(queue)
ensure
  FileUtils.rm_rf(w)
end

test "steering_loop: graceful interrupt (one more pass) and hard abort (rollback)" do
  w = workspace
  queue = File.join(w, "steer.jsonl")
  interrupt = File.join(w, "interrupt")
  abort = File.join(w, "abort")
  File.write(interrupt, "wrap up now")

  passes = 0
  app = ->(env) { passes += 1; env[:messages] << msg(:assistant, "r#{passes}"); env }
  env = env_with([msg(:user, "start")])
  SteeringLoop.new(app, queue: queue, interrupt_file: interrupt, abort_file: abort).call(env)
  assert_equal 2, passes # hint pass, then stop
  assert_equal "wrap up now", env[:messages].map(&:content).find { |c| c == "wrap up now" }
  refute File.exist?(interrupt)

  path = File.join(w, "sessions", "s.jsonl")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, JSON.generate(msg(:user, "old").to_h) + "\n")
  File.write(abort, "")
  app2 = ->(env) { env[:messages] << msg(:assistant, "progress"); env }
  env = env_with([msg(:user, "new")])
  stack = SteeringLoop.new(app2, queue: queue, interrupt_file: interrupt, abort_file: abort)
  SessionStore.new(stack, path: path).call(env)
  assert_equal "new", env[:messages].last.content # rolled back to old + new
  refute File.exist?(abort)
ensure
  FileUtils.rm_rf(w)
end

# --- emergency_compression -----------------------------------------------------------------

test "emergency_compression: transient retry, context compress+retry, hard errors propagate" do
  w = workspace
  summary = File.join(w, "s.summary.md")

  attempts = 0
  flaky = lambda do |env|
    attempts += 1
    raise "connection reset by peer" if attempts < 2

    env
  end
  EmergencyCompression.new(flaky, backoff_secs: 0, summary_path: summary).call(env_with([msg(:user, "hi")]))
  assert_equal 2, attempts

  calls = 0
  contexty = lambda do |env|
    calls += 1
    raise "context_length_exceeded" if calls == 1

    env
  end
  messages = [msg(:system, "S")] + 6.times.flat_map { |i| [msg(:user, "u#{i}"), msg(:assistant, "a#{i}")] }
  env = env_with(messages)
  EmergencyCompression.new(contexty, summary_path: summary, max_tokens: 100, context_window: 100_000).call(env)
  assert_equal 2, calls
  assert env[:messages].size < 13
  assert_equal :system, env[:messages].first.role.to_sym
  assert_includes File.read(summary), "Emergency compression dropped"

  fatal = ->(_env) { raise "invalid api key" }
  err = assert_raises(RuntimeError) do
    EmergencyCompression.new(fatal, backoff_secs: 0, summary_path: summary).call(env_with([msg(:user, "hi")]))
  end
  assert_equal "invalid api key", err.message
ensure
  FileUtils.rm_rf(w)
end

# --- state_manager -----------------------------------------------------------------------

test "state_manager: writes state.json on unwind" do
  w = workspace
  path = File.join(w, "state", "state.json")
  env = env_with([msg(:user, "hi")])
  StateManager.new(->(e) { e }, path: path).call(env)
  state = JSON.parse(File.read(path))
  assert_equal "cli", state["last_channel"]
  assert_equal "direct", state["last_chat_id"]
  assert state["timestamp"]
  assert_equal 0o600, File.stat(path).mode & 0o777
ensure
  FileUtils.rm_rf(w)
end

puts "\n#{$count} tests, #{$failures.size} failures"
exit($failures.empty? ? 0 : 1)
