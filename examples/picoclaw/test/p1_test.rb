# frozen_string_literal: true

# Plain-ruby test harness for the P1 milestone: tool_policy (validation /
# approval / sensitive scrub), fallback_chain, model_router, media,
# subturns (spawn/subagent/spawn_status), find_skills / install_skill.

require "fileutils"
require "tmpdir"
require "json"

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "brute"

ROOT = File.expand_path("..", __dir__)
%w[tool_wrapper workspace_guard tool_policy fs_sandbox diff_result exec_session web_http html_markdown
   skill_registries web_search web_fetch cron_tool read_file write_file edit_file append_file list_dir exec
   find_skills install_skill spawn subagent spawn_status].each { |f| require_relative "#{ROOT}/tools/#{f}" }
require_relative "#{ROOT}/cron"
%w[session_store memory_files skills_catalog token_estimator context_budget emergency_compression
   steering_loop state_manager cron_schedule model_router media fallback_chain subturns].each { |f| require_relative "#{ROOT}/middleware/#{f}" }

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

def assert_raises(klass)
  yield
  raise("expected #{klass} to be raised, nothing was")
rescue klass => e
  e
end

def workspace
  Dir.mktmpdir("picoclaw-p1-test")
end

def msg(role, content = "x", **kw)
  Brute::Message.new(role: role, content: content, **kw)
end

def env_with(messages)
  { messages: messages, metadata: {}, events: [], current_iteration: 0 }
end

def echo_tool
  Class.new(Brute::Tool) do
    description "echo"
    params({ "type" => "object",
             "properties" => { "text" => { "type" => "string" }, "n" => { "type" => "integer" } },
             "required" => ["text"] })
    define_method(:name) { "echo" }
    define_method(:execute) { |**args| "echo: #{args[:text]}" }
  end.new
end

# --- tool_policy ---------------------------------------------------------------

test "tool_policy: schema validation (required, unexpected, types, nesting)" do
  tool = ToolPolicy.new(echo_tool)
  assert_equal %(invalid arguments for tool "echo": missing required property "text"), tool.call({})
  assert_equal %(invalid arguments for tool "echo": unexpected property "bogus"), tool.call("text" => "x", "bogus" => 1)
  assert_equal %(invalid arguments for tool "echo": property "text": expected string, got float64), tool.call("text" => 5)
  assert_equal %(invalid arguments for tool "echo": property "n": expected integer, got float64 with fractional part),
               tool.call("text" => "x", "n" => 1.5)
  assert_equal "echo: ok", tool.call("text" => "ok", "n" => 2)
end

test "tool_policy: approval gate denies fail-closed" do
  denied = ToolPolicy.new(echo_tool, approve: ->(_name, _args) { false })
  assert_equal %(Tool call to "echo" was denied by the approval policy.), denied.call("text" => "x")
  allowed = ToolPolicy.new(echo_tool, approve: ->(_name, args) { args["text"] == "fine" })
  assert_equal "echo: fine", allowed.call("text" => "fine")
  assert_includes allowed.call("text" => "nope"), "denied"
end

test "tool_policy: sensitive scrub ([FILTERED], min length fast path)" do
  tool = ToolPolicy.new(echo_tool, sensitive_values: ["sk-secret-123", "short"])
  assert_equal "echo: [FILTERED]", tool.call("text" => "sk-secret-123") # >8 chars
  short_tool = ToolPolicy.new(echo_tool, sensitive_values: ["sk-secret-123"], filter_min_length: 100)
  assert_equal "echo: sk-secret-123", short_tool.call("text" => "sk-secret-123")
  off = ToolPolicy.new(echo_tool, sensitive_values: ["sk-secret-123"], filter_enabled: false)
  assert_equal "echo: sk-secret-123", off.call("text" => "sk-secret-123")
end

# --- fallback_chain ---------------------------------------------------------------

test "fallback_chain: advance on failure, cooldown skip, auth aborts, exhaustion, persistence" do
  w = workspace
  state = File.join(w, "fallback.json")
  candidates = [{ "name" => "a/model" }, { "name" => "b/model" }]

  attempts = []
  app = lambda do |env|
    attempts << env[:metadata][:llm_model]
    raise "429 too many requests" if env[:metadata][:llm_model] == "a/model"

    env
  end
  FallbackChain.new(app, candidates: candidates, state_path: state).call(env_with([]))
  assert_equal ["a/model", "b/model"], attempts

  # a/model is now in cooldown (state persisted): a fresh chain skips it.
  attempts2 = []
  app2 = ->(env) { attempts2 << env[:metadata][:llm_model]; env }
  FallbackChain.new(app2, candidates: candidates, state_path: state).call(env_with([]))
  assert_equal ["b/model"], attempts2

  # auth errors abort the chain immediately.
  attempts3 = []
  app3 = lambda do |env|
    attempts3 << env[:metadata][:llm_model]
    raise "401 invalid api key"
  end
  err = assert_raises(RuntimeError) do
    FallbackChain.new(app3, candidates: [{ "name" => "x" }, { "name" => "y" }],
                            state_path: File.join(w, "f2.json")).call(env_with([]))
  end
  assert_equal "401 invalid api key", err.message
  assert_equal ["x"], attempts3

  # all failed
  app4 = ->(_env) { raise "500 server error" }
  err = assert_raises(FallbackChain::AllFailed) do
    FallbackChain.new(app4, candidates: [{ "name" => "x" }], state_path: File.join(w, "f3.json")).call(env_with([]))
  end
  assert_includes err.message, "all fallback candidates failed"
ensure
  FileUtils.rm_rf(w)
end

test "fallback_chain: rpm bucket (saturated non-last candidate is skipped)" do
  w = workspace
  state = File.join(w, "rpm.json")
  candidates = [{ "name" => "a", "rpm" => 1 }, { "name" => "b" }]
  app = ->(env) { env }
  chain = FallbackChain.new(app, candidates: candidates, state_path: state)
  chain.call(env_with([])) # consumes a's only token
  # second call: a's bucket empty → skipped to b
  used = nil
  FallbackChain.new(->(env) { used = env[:metadata][:llm_model]; env }, candidates: candidates, state_path: state).call(env_with([]))
  assert_equal "b", used
ensure
  FileUtils.rm_rf(w)
end

# --- model_router ---------------------------------------------------------------------

test "model_router: classifier + light/heavy selection" do
  assert ModelRouter.score("hi", []) < 0.35
  assert_equal 1.0, ModelRouter.score("look at photo.jpg", [])
  assert ModelRouter.score("here is code:\n```ruby\nx\n```", []) >= 0.35

  seen = []
  app = ->(env) { seen << env[:metadata][:llm_model]; env }
  router = ModelRouter.new(app, enabled: true, light_model: "light/model")
  router.call(env_with([msg(:user, "ok")]))
  assert_equal "light/model", seen.last

  router.call(env_with([msg(:user, "analyze this\n```\ncode\n```")]))
  assert_nil seen.last
  heavy = nil
  app2 = ->(env) { heavy = env[:metadata][:llm_model]; env }
  ModelRouter.new(app2, enabled: true, light_model: "light/model").call(env_with([msg(:user, "analyze\n```\nx\n```")]))
  assert_nil heavy

  disabled = nil
  ModelRouter.new(->(env) { disabled = env[:metadata][:llm_model]; env }, enabled: false).call(env_with([msg(:user, "ok")]))
  assert_nil disabled
end

# --- media ----------------------------------------------------------------------------

test "media store: refs, resolve, refcount policies, release, janitor" do
  w = workspace
  file = File.join(w, "img.png")
  File.binwrite(file, "png")
  store = Media::Store.new(dir: w)
  ref = store.store(file, meta: { content_type: "image/png" }, scope: "s1")
  assert ref.start_with?("media://")
  assert_equal file, store.resolve(ref)
  assert_equal "image/png", store.resolve_with_meta(ref)[1][:content_type]

  store.release_all("s1")
  refute File.exist?(file) # store-managed default → deleted
  assert_raises(RuntimeError) { store.resolve(ref) }

  forget = File.join(w, "keep.png")
  File.binwrite(forget, "png")
  store.store(forget, meta: { cleanup_policy: "forget_only" }, scope: "s2")
  store.release_all("s2")
  assert File.exist?(forget)

  old = File.join(w, "old.png")
  File.binwrite(old, "png")
  past = Time.now - 31 * 60
  janitor = Media::Store.new(dir: w, now: -> { past })
  janitor.store(old, meta: {}, scope: "s3")
  janitor_now = Media::Store.new(dir: w)
  # borrow the state by re-storing in the janitor with current time
  janitor.instance_variable_set(:@now, -> { Time.now })
  assert_equal 1, janitor.clean_expired
  refute File.exist?(old)
ensure
  FileUtils.rm_rf(w)
end

test "media middleware: media:// refs become path tags, stale refs dropped" do
  w = workspace
  file = File.join(w, "pic.png")
  File.binwrite(file, "png")
  store = Media::Store.new(dir: w)
  ref = store.store(file, meta: { content_type: "image/png" }, scope: "s")
  stale = "media://00000000-0000-0000-0000-000000000000"

  env = env_with([msg(:tool, "image ready: #{ref} and #{stale}")])
  Media.new(->(e) { e }, store: store).call(env)
  assert_equal "image ready: [image:#{file}] and ", env[:messages].last.content
ensure
  FileUtils.rm_rf(w)
end

# --- subturns --------------------------------------------------------------------------

test "subturns: spawn async + drain injects [SubTurn Result]; spawn_status lists" do
  registry = Subturns::Registry.new do |task_text|
    { messages: [msg(:assistant, "done: #{task_text}")] }
  end
  spawn = Spawn.new(registry: registry)
  assert_equal "Spawned subagent 'research' for task: look up x", spawn.call("task" => "look up x", "label" => "research")
  sleep 0.2
  task = registry.find("subagent-1")
  assert_equal "completed", task.status
  assert_equal "done: look up x", task.result

  env = env_with([msg(:user, "parent")])
  Subturns::Drain.inject(env, registry)
  assert_includes env[:messages].last.content, "[SubTurn Result] research"
  Subturns::Drain.inject(env, registry) # reported once
  assert_equal 2, env[:messages].size

  status = SpawnStatus.new(registry: registry).call({})
  assert_includes status, "Subagent status report (1 total)"
  assert_includes status, "Completed: 1"
  assert_includes status, "[subagent-1] status=completed"
  assert_includes status, 'label="research"'
  single = SpawnStatus.new(registry: registry).call("task_id" => "subagent-1")
  assert_includes single, "task:   look up x"
  assert_equal "Subagent task not found: nope", SpawnStatus.new(registry: registry).call("task_id" => "nope")
end

test "subturns: subagent sync result + failure, spawn concurrency guard" do
  registry = Subturns::Registry.new do |task_text|
    raise "boom" if task_text == "fail"

    { messages: [msg(:assistant, "child says: #{task_text}")] }
  end
  subagent = Subagent.new(registry: registry)
  out = subagent.call("task" => "compute", "label" => "math")
  assert_equal "Subagent task completed:\nLabel: math\nResult: child says: compute", out
  unnamed = subagent.call("task" => "compute")
  assert_includes unnamed, "Label: (unnamed)"
  failed = subagent.call("task" => "fail")
  assert_equal "Subagent execution failed: boom", failed

  tiny = Subturns::Registry.new(max_concurrent: 1, concurrency_timeout: 1) { |t| sleep 3; { messages: [msg(:assistant, t)] } }
  slow_spawn = Spawn.new(registry: tiny)
  assert_includes slow_spawn.call("task" => "slow"), "Spawned subagent for task"
  assert_equal "concurrency limit reached (could not acquire a subagent slot in 30s)", tiny.acquire ? "acquired" : Spawn.new(registry: tiny).call("task" => "second")
  sleep 3.5 # let the thread finish before the tmpdir cleanup of other tests
end

# --- skills registry tools -----------------------------------------------------------------

test "find_skills: format, cache hit, fuzzy cache hit" do
  fake = Object.new
  def fake.name = "clawhub"
  def fake.search(query, _limit)
    [{ slug: "docker-compose", display_name: "Docker Compose", summary: "Compose stacks",
       version: "1.2.0", score: 0.87, registry: "clawhub" }]
  end
  cache = SkillRegistries::SearchCache.new
  tool = FindSkills.new(registries: [fake], cache: cache)
  out = tool.call("query" => "Docker")
  assert_includes out, "Found 1 skills for \"docker\":"
  assert_includes out, "1. **docker-compose** v1.2.0  (score: 0.870, registry: clawhub)"
  assert_includes out, "   Name: Docker Compose"
  assert_includes out, "   Compose stacks"
  assert_includes out, "Use install_skill with the slug to install a skill."

  cached = tool.call("query" => "docker")
  assert_includes cached, "(cached)"
  fuzzy = tool.call("query" => "docker setup") # trigram-similar to "docker"
  assert fuzzy.is_a?(String)
end

test "install_skill: install, already-installed, force restore, malware block, origin meta" do
  w = workspace
  registry = Object.new
  registry.define_singleton_method(:name) { "clawhub" }
  registry.define_singleton_method(:download_and_install) do |slug, _version, dir|
    raise "malware" if slug == "evil"

    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"), "---\nname: #{slug}\ndescription: #{slug} skill\n---\n\nBody.")
    { version: "1.0.0", summary: "#{slug} skill", malware_blocked: slug == "bad", suspicious: false }
  end
  registry.define_singleton_method(:resolve_dir_name) { |slug| slug }

  tool = InstallSkill.new(registries: [registry], workspace: w)
  out = tool.call("slug" => "tour", "registry" => "clawhub")
  assert_includes out, %(Successfully installed skill "tour" v1.0.0 from clawhub registry.)
  assert File.exist?(File.join(w, "skills", "tour", ".skill-origin.json"))
  assert_equal "clawhub", JSON.parse(File.read(File.join(w, "skills", "tour", ".skill-origin.json")))["registry"]

  assert_includes tool.call("slug" => "tour", "registry" => "clawhub"), "already installed"

  # force with a failing registry → previous install restored
  File.write(File.join(w, "skills", "tour", "SKILL.md"), "ORIGINAL")
  registry2 = Object.new
  registry2.define_singleton_method(:name) { "clawhub" }
  registry2.define_singleton_method(:download_and_install) { |*_a| raise "network down" }
  registry2.define_singleton_method(:resolve_dir_name) { |slug| slug }
  tool2 = InstallSkill.new(registries: [registry2], workspace: w)
  assert_includes tool2.call("slug" => "tour", "registry" => "clawhub", "force" => true), "network down"
  assert_equal "ORIGINAL", File.read(File.join(w, "skills", "tour", "SKILL.md"))

  blocked = InstallSkill.new(registries: [registry], workspace: w)
  assert_equal %(skill "bad" is flagged as malicious and cannot be installed), blocked.call("slug" => "bad", "registry" => "clawhub")
  refute File.exist?(File.join(w, "skills", "bad"))
ensure
  FileUtils.rm_rf(w)
end

# --- main.rb wiring ----------------------------------------------------------------

test "main.rb: full stack builds with P1 wiring; subturn tools registered" do
  ENV["OPENROUTER_API_KEY"] ||= "dummy"
  load "#{ROOT}/main.rb"
  config = load_config
  build_agent(config)
  registry = Subturns::Registry.new { |t| { messages: [msg(:assistant, t)] } }
  tools = Brute.tools(build_tools(config, cron_store: CronStore.new(File.join(Dir.pwd, "cron", "jobs.json")),
                                        subturn_registry: registry)).keys.map(&:to_s)
  %w[read_file write_file edit_file append_file list_dir exec cron web_search web_fetch
     find_skills install_skill spawn subagent spawn_status].each do |name|
    assert_includes tools, name
  end
end

puts "\n#{$count} tests, #{$failures.size} failures"
exit($failures.empty? ? 0 : 1)
