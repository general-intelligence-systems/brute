#!/usr/bin/env ruby
# frozen_string_literal: true

# picoclaw-clone — PicoClaw (https://github.com/sipeed/picoclaw) re-implemented
# in Ruby on the brute agent framework. Autonomous agent: runs one heartbeat
# turn per invocation, driven by the flake's systemd timer.

require "json"
require "tmpdir"
require "yaml"

require "open_router"
require "brute"

require_relative "cron"
require_relative "hooks"

require_relative "tools/tool_wrapper"
require_relative "tools/workspace_guard"
require_relative "tools/tool_policy"
require_relative "tools/fs_sandbox"
require_relative "tools/diff_result"
require_relative "tools/exec_session"
require_relative "tools/web_http"
require_relative "tools/html_markdown"
require_relative "tools/skill_registries"
require_relative "tools/web_search"
require_relative "tools/web_fetch"
require_relative "tools/cron_tool"
require_relative "tools/read_file"
require_relative "tools/write_file"
require_relative "tools/edit_file"
require_relative "tools/append_file"
require_relative "tools/list_dir"
require_relative "tools/exec"
# picoclaw tool scaffolds — no-op handlers returning {"error":"not implemented"}
# until filled in (FEATURES.md Part 1, tracked in TODO.md).
require_relative "tools/load_image"
require_relative "tools/find_skills"
require_relative "tools/install_skill"
require_relative "tools/spawn"
require_relative "tools/subagent"
require_relative "tools/spawn_status"

require_relative "middleware/heartbeat_gate"
require_relative "middleware/evolution_log"
require_relative "middleware/cron_schedule"
require_relative "middleware/compaction"
require_relative "middleware/steering_loop"
# picoclaw middleware scaffolds — no-op pass-throughs until filled in
# (FEATURES.md Part 2, tracked in TODO.md).
require_relative "middleware/runtime_events"
require_relative "middleware/state_manager"
require_relative "middleware/session_store"
require_relative "middleware/skills_catalog"
require_relative "middleware/memory_files"
require_relative "middleware/system_prompt"
require_relative "middleware/token_estimator"
require_relative "middleware/context_budget"
require_relative "middleware/emergency_compression"
require_relative "middleware/model_router"
require_relative "middleware/media"
require_relative "middleware/fallback_chain"
require_relative "middleware/subturns"

# Set OPENROUTER_API_KEY in the environment.
OpenRouter.configure do |config|
  config.access_token = ENV.fetch("OPENROUTER_API_KEY")
end

CONFIG_PATH = File.join(Dir.pwd, "config.json").freeze
DEFAULT_CONFIG = { "model" => nil, "restrict_to_workspace" => true, "allow_read_outside_workspace" => false,
                   "max_tokens" => 8192, "context_window" => 0, "summarize_message_threshold" => 20,
                   "summarize_token_percent" => 75, "steering_mode" => "one-at-a-time" }.freeze

def load_config
  config = File.exist?(CONFIG_PATH) ? JSON.parse(File.read(CONFIG_PATH)) : {}
  DEFAULT_CONFIG.merge(config)
rescue JSON::ParserError => e
  warn "config.json: #{e.message} — using defaults"
  DEFAULT_CONFIG.dup
end

def workspace_file(name)
  path = File.join(Dir.pwd, name)
  File.exist?(path) ? File.read(path).strip : nil
end

# The system prompt: an ERB template + named sections, each re-read from the
# workspace on every turn (picoclaw's mtime hot-reload).
def prompt_template(session: "heartbeat")
  Brute::PromptTemplate.new(
    File.expand_path("prompt.erb", __dir__),
    agents:      -> { workspace_file("AGENTS.md") },
    soul:        -> { workspace_file("SOUL.md") },
    user:        -> { workspace_file("USER.md") },
    memory:      ->(ctx) { ctx[:memory_part] },   # MemoryFiles middleware
    summary:     -> { workspace_file(File.join("sessions", "#{session}.summary.md")) },
    environment: ->(ctx) { Brute::Prompts::Environment.call(ctx) },
    skills:      ->(ctx) { ctx[:skills_part] },   # SkillsCatalog middleware
    workspace:   Dir.pwd,
  )
end

# One-off LLM call for the Compaction middleware — no tools, no middleware,
# reusing the working OpenRouter transport path.
def summarizer(config)
  options = {}
  options[:model] = config["model"] if config["model"]

  lambda do |prompt|
    env = Brute.agent
      .run(Brute::Middleware::OpenRouter::Completion.new({}, **options))
      .start(prompt)
    env[:messages].last.content.to_s
  end
end

# Regex-compile config path patterns; invalid ones are dropped with a warning
# (picoclaw compilePatterns, pkg/agent/instance.go:433-447).
def compile_patterns(list)
  Array(list).filter_map do |pattern|
    begin
      Regexp.new(pattern.to_s)
    rescue RegexpError => e
      warn "invalid path pattern #{pattern.inspect}: #{e.message}"
      nil
    end
  end
end

# Upstream always allows reads under the media temp dir (instance.go:449-469).
MEDIA_TMP_PATTERN = %r{\A#{Regexp.escape(File.join(Dir.tmpdir, "picoclaw_media"))}(?:/|$)}.freeze

# The agent's tool list. The six core fs/exec tools self-guard — picoclaw's
# sandbox lives inside the tools (pkg/tools/fs, shell.go), so wrapping them in
# WorkspaceGuard would wrongly reject allow_read/allow_writePaths matches.
# Stand-ins and scaffolds keep the guard.
def build_tools(config, cron_store:, subturn_registry: nil)
  workspace = Dir.pwd
  restrict = config.fetch("restrict_to_workspace", true)
  read_restrict = restrict && !config["allow_read_outside_workspace"]

  tools_cfg = config["tools"] || {}
  allow_read = compile_patterns(tools_cfg["allow_read_paths"]) + [MEDIA_TMP_PATTERN]
  allow_write = compile_patterns(tools_cfg["allow_write_paths"])
  read_cfg = tools_cfg["read_file"] || {}
  exec_cfg = tools_cfg["exec"] || {}

  # Upstream logs the construction failure and continues without exec
  # (pkg/agent/instance.go:129-137).
  exec_tool =
    begin
      Exec.new(workspace:, restrict:,
               timeout: exec_cfg["timeout_seconds"] || 60,
               enable_deny_patterns: exec_cfg.fetch("enable_deny_patterns", true),
               allow_remote: exec_cfg.fetch("allow_remote", true),
               custom_deny_patterns: exec_cfg["custom_deny_patterns"] || [],
               custom_allow_patterns: exec_cfg["custom_allow_patterns"] || [],
               allow_paths: allow_read)
    rescue ArgumentError => e
      warn "Failed to initialize exec tool; continuing without exec: #{e.message}"
      nil
    end

  list = [
    ReadFile.new(workspace:, restrict: read_restrict,
                 mode: read_cfg["mode"] || "bytes",
                 max_size: read_cfg["max_read_file_size"],
                 allow_paths: allow_read),
    WriteFile.new(workspace:, restrict:, allow_paths: allow_write),
    EditFile.new(workspace:, restrict:, allow_paths: allow_write),
    AppendFile.new(workspace:, restrict:, allow_paths: allow_write),
    ListDir.new(workspace:, restrict: read_restrict, allow_paths: allow_read),
    exec_tool,
  ].compact

  web_cfg = tools_cfg["web"] || {}
  cron_cfg = tools_cfg["cron"] || {}
  skills_cfg = tools_cfg["skills"] || {}
  registries = build_skill_registries(skills_cfg, web_cfg)

  guarded = [
    Brute::Tools::FSRemove.new,  # no picoclaw counterpart
    Brute::Tools::SkillLoad.new,
    LoadImage.new,               # scaffold
  ]
  # Upstream leaves web_search unregistered when no provider is ready
  # (NewWebSearchTool returns nil); sogou is enabled by default.
  guarded << WebSearch.new(options: web_cfg) if WebSearch.registerable?(web_cfg)
  guarded = guarded.map { |tool| WorkspaceGuard.new(tool) } if restrict

  list = list + guarded + [
    CronTool.new(store: cron_store,
                 exec_enabled: exec_cfg.fetch("enabled", true) && !exec_tool.nil?,
                 allow_command: cron_cfg.fetch("allow_command", true),
                 command_allowed_remotes: cron_cfg["command_allowed_remotes"] || []),
    WebFetch.new(format: web_cfg["format"] || "plaintext",
                 proxy: web_cfg["proxy"],
                 fetch_limit_bytes: web_cfg["fetch_limit_bytes"],
                 private_host_whitelist: web_cfg["private_host_whitelist"] || []),
    FindSkills.new(registries: registries),
    InstallSkill.new(registries: registries, workspace: workspace),
    *spawn_tools(subturn_registry),
  ]

  # AGENT.md/AGENTS.md frontmatter `tools:` allowlist filters registration
  # (upstream registry.SetAllowlist): nil = all, [] = none.
  list = apply_tool_allowlist(list, workspace)

  # The per-tool-call policy layer wraps everything (validate.go arg
  # validation + approval seam + sensitive-data scrub of results).
  secrets = collect_sensitive_values(config)
  require_approval = Array(tools_cfg["require_approval"])
  filter_enabled = tools_cfg.fetch("filter_sensitive_data", true)
  filter_min = tools_cfg["filter_min_length"] || 8
  list.map do |tool|
    ToolPolicy.new(tool,
                   sensitive_values: secrets,
                   filter_enabled: filter_enabled,
                   filter_min_length: filter_min,
                   approve: approval_policy(require_approval, workspace))
  end
end

def spawn_tools(registry)
  return [] unless registry

  [Spawn.new(registry: registry), Subagent.new(registry: registry), SpawnStatus.new(registry: registry)]
end

# tools.skills.registries (default: clawhub + github, both enabled).
def build_skill_registries(skills_cfg, web_cfg)
  proxy = web_cfg["proxy"]
  github_legacy = skills_cfg["github"] || {}
  entries = skills_cfg["registries"] || [{ "name" => "clawhub", "enabled" => true },
                                         { "name" => "github", "enabled" => true }]
  entries.filter_map do |entry|
    next unless entry["enabled"]

    case entry["name"]
    when "clawhub"
      SkillRegistries::ClawHub.new(base_url: entry["base_url"], auth_token: entry["auth_token"], proxy: proxy)
    when "github"
      SkillRegistries::GitHub.new(token: entry["token"] || github_legacy["token"],
                                  api_base: entry["api_base"],
                                  web_base: entry["base_url"] || github_legacy["base_url"],
                                  proxy: entry["proxy"] || github_legacy["proxy"] || proxy)
    end
  end
end

# Secret collection for the result scrubber: every string value under an
# api_key/api_keys/token/secret/password key (plus the provider key from env).
def collect_sensitive_values(config, keys = [])
  values = []
  walk = lambda do |node|
    case node
    when Hash
      node.each do |k, v|
        if k.to_s.match?(/api_key|api_keys|token|secret|password/i)
          values.concat(Array(v).map(&:to_s))
        else
          walk.call(v)
        end
      end
    when Array
      node.each { |v| walk.call(v) }
    end
  end
  walk.call(config)
  values << ENV["OPENROUTER_API_KEY"].to_s
  values.reject(&:empty?)
end

def apply_tool_allowlist(tools, workspace)
  allowed = agent_tool_allowlist(workspace)
  return tools if allowed.nil?

  names = allowed.map { |n| n.to_s.downcase }
  tools.select { |tool| names.include?(Brute::Tools::Adapter.wrap(tool).name.to_s.downcase) }
end

def agent_tool_allowlist(workspace)
  %w[AGENT.md AGENTS.md].each do |file|
    path = File.join(workspace, file)
    next unless File.file?(path)

    raw = File.read(path)
    next unless raw.start_with?("---\n")

    closing = raw.index("\n---", 4)
    next unless closing

    frontmatter = YAML.safe_load(raw[4...closing]) rescue nil
    return frontmatter["tools"] if frontmatter.is_a?(Hash) && frontmatter.key?("tools")
  end
  nil
end

# tools.require_approval: listed tools are denied (fail-closed) and the call
# is staged to pending/approvals/ for an operator to review (hermes' staged
# write pattern; there is no interactive surface in this port).
def approval_policy(require_approval, workspace)
  lambda do |name, args|
    next true unless require_approval.include?(name)

    dir = File.join(workspace, "pending", "approvals")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)}-#{name}.json"),
               JSON.pretty_generate("tool" => name, "arguments" => args, "staged_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")))
    false
  end
end

# --- Workflow (built middleware-by-middleware) -------------------------------

def build_agent(config, session: "heartbeat")
  cron_store = CronStore.new(File.join(Dir.pwd, "cron", "jobs.json"))
  tool_list = nil # assigned below; the registry's build_child reads it lazily
  subturn_registry = build_subturn_registry(config) { tool_list }
  tool_list = build_tools(config, cron_store:, subturn_registry:)

  # ToolPipeline executes env[:tools]; the provider learns about them through
  # CompletionOptions#tools, serialized as OpenAI-wire function definitions.
  advertised = Brute.tools(tool_list).values.map do |adapter|
    { type: "function", function: adapter.to_h }
  end

  options = { tools: advertised }
  options[:model] = config["model"] if config["model"]

  cron_cfg = (config["tools"] || {})["cron"] || {}
  cron_minutes = cron_cfg["exec_timeout_minutes"] || 5
  cron_exec = Exec.new(workspace: Dir.pwd, restrict: config.fetch("restrict_to_workspace", true),
                       timeout: cron_minutes.positive? ? cron_minutes * 60 : 0)
  summary_path = File.join(Dir.pwd, "sessions", "#{session}.summary.md")
  routing_cfg = config["routing"] || {}
  cleanup_cfg = (config["tools"] || {})["media_cleanup"] || {}

  # The terminal proc resolves the model per call — ModelRouter's light pick
  # and FallbackChain's candidate both flow through env[:metadata][:llm_model].
  terminal = proc do |env|
    opts = options.dup
    opts[:model] = env[:metadata][:llm_model] if env[:metadata][:llm_model]
    Brute::Middleware::OpenRouter::Completion.new({}, **opts).call(env)
  end

  pipeline = Brute.agent
    .use(HeartbeatGate)
    .use(RuntimeEvents)           # scaffold (no-op) — turn-span event bus
    .use(StateManager)
    .use(EvolutionLog, path: File.join(Dir.pwd, ".evolution", "records.jsonl"))
    .use(SessionStore, path: File.join(Dir.pwd, "sessions", "#{session}.jsonl"))
    .use(CronSchedule, store: cron_store, exec_tool: cron_exec)
    .use(SkillsCatalog)
    .use(MemoryFiles)
    .use(Compaction, threshold: config["summarize_message_threshold"] || 20,
                     token_percent: config["summarize_token_percent"] || 75,
                     context_window: config["context_window"],
                     summary_path: summary_path,
                     summarize: summarizer(config))
    .use(SystemPrompt)            # scaffold (no-op) — will absorb Brute::Middleware::SystemPrompt + prompt.erb
    .use(Brute::Middleware::SystemPrompt, system_prompt: prompt_template(session:))
    .use(ContextBudget, tool_defs: advertised,
                        max_tokens: config["max_tokens"],
                        context_window: config["context_window"],
                        summary_path: summary_path)
    .use(ModelRouter, enabled: routing_cfg.fetch("enabled", false),
                      light_model: routing_cfg["light_model"],
                      threshold: routing_cfg["threshold"] || 0.35)
    .use(Media, store: Media::Store.new(max_age_minutes: cleanup_cfg["max_age_minutes"] || 30),
                enabled_cleanup: cleanup_cfg.fetch("enabled", true))
    .use(SteeringLoop, mode: config["steering_mode"] || "one-at-a-time")
    .use(Subturns, registry: subturn_registry)
    .use(Subturns::Drain, registry: subturn_registry)
    .use(Brute::Middleware::MaxIterations)
    .use(Brute::Middleware::ToolPipeline, tools: tool_list)
    .use(EmergencyCompression, summary_path: summary_path,
                               tool_defs: advertised,
                               max_tokens: config["max_tokens"],
                               context_window: config["context_window"],
                               max_retries: config["max_llm_retries"] || 2,
                               backoff_secs: config["llm_retry_backoff_secs"] || 2)

  # Upstream: single candidate → plain call (no chain); >1 → the fallback chain.
  candidates = fallback_candidates(config)
  if candidates.size > 1
    pipeline.use(FallbackChain, candidates: candidates,
                                state_path: File.join(Dir.pwd, "state", "fallback_chain.json"))
  end

  HookManager.new(config: config, session: session).wire(pipeline)
  pipeline.run(terminal)
end

# primary + model_fallbacks; per-model rpm from config["models"][name]["rpm"].
def fallback_candidates(config)
  models = config["models"] || {}
  [config["model"], *Array(config["model_fallbacks"])].compact.map do |name|
    { "name" => name, "rpm" => (models[name] || {})["rpm"] }
  end
end

# Children run a minimal stack: fixed subagent prompt, ephemeral session, the
# parent's tools minus the spawn set (no recursive spawning), same model.
def build_subturn_registry(config, &tool_list_proc)
  sub_cfg = config["subturn"] || {}
  Subturns::Registry.new(
    max_depth: sub_cfg["max_depth"] || 3,
    max_concurrent: sub_cfg["max_concurrent"] || 5,
    concurrency_timeout: sub_cfg["concurrency_timeout_sec"] || 30,
    default_timeout_minutes: sub_cfg["default_timeout_minutes"] || 5,
  ) do |task_text|
    tool_list = tool_list_proc.call
    excluded = %i[spawn subagent spawn_status]
    sub_tools = tool_list.reject { |t| excluded.include?(Brute::Tools::Adapter.wrap(t).name.to_sym) }
    sub_advertised = Brute.tools(sub_tools).values.map { |a| { type: "function", function: a.to_h } }
    sub_options = { tools: sub_advertised }
    sub_options[:model] = config["model"] if config["model"]

    agent = Brute.agent
      .use(Brute::Middleware::MaxIterations)
      .use(Brute::Middleware::ToolPipeline, tools: sub_tools)
      .use(EmergencyCompression, summary_path: nil, tool_defs: sub_advertised,
                                 max_tokens: config["max_tokens"], context_window: config["context_window"])
      .run(Brute::Middleware::OpenRouter::Completion.new({}, **sub_options))

    env = { messages: Brute.log, events: [], metadata: {}, current_iteration: 1 }
    env[:messages] << Brute::Message.new(role: :system, content: "#{Subturns::SYSTEM_PROMPT}\n\nTask: #{task_text}")
    env[:messages] << Brute::Message.new(role: :user, content: task_text)
    agent.to_app.call(env)
    env
  end
end

def reply(env)
  env[:messages].reverse.find { |m| m.role == :assistant && !m.content.to_s.strip.empty? }&.content.to_s
end

if __FILE__ == $PROGRAM_NAME
  # Bare invocation = one heartbeat turn (what the systemd timer runs).
  # Positional args are a dev/test driver: bypasses the gate, separate session.
  heartbeat = ARGV.empty?
  message = heartbeat ? HeartbeatGate::TRIGGER : ARGV.join(" ")
  result = reply(build_agent(load_config, session: heartbeat ? "heartbeat" : "dev").start(message))
  puts result

  # picoclaw logs heartbeat activity to heartbeat.log in the workspace.
  File.open(File.join(Dir.pwd, "heartbeat.log"), "a") do |f|
    f.puts("[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}] [INFO] #{result.lines.first&.strip}")
  end
end
