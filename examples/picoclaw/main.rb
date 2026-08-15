#!/usr/bin/env ruby
# frozen_string_literal: true

# picoclaw-clone — PicoClaw (https://github.com/sipeed/picoclaw) re-implemented
# in Ruby on the brute agent framework. Autonomous agent: runs one heartbeat
# turn per invocation, driven by the flake's systemd timer.

require "json"
require "tmpdir"

require "open_router"
require "brute"

require_relative "cron"

require_relative "tools/tool_wrapper"
require_relative "tools/workspace_guard"
require_relative "tools/fs_sandbox"
require_relative "tools/diff_result"
require_relative "tools/exec_session"
require_relative "tools/web_http"
require_relative "tools/html_markdown"
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
require_relative "middleware/tool_policy"

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
def build_tools(config, cron_store:)
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

  guarded = [
    Brute::Tools::FSRemove.new,  # no picoclaw counterpart
    Brute::Tools::SkillLoad.new,
    LoadImage.new,               # scaffold
  ]
  # Upstream leaves web_search unregistered when no provider is ready
  # (NewWebSearchTool returns nil); sogou is enabled by default.
  guarded << WebSearch.new(options: web_cfg) if WebSearch.registerable?(web_cfg)
  guarded = guarded.map { |tool| WorkspaceGuard.new(tool) } if restrict

  list + guarded + [
    CronTool.new(store: cron_store,
                 exec_enabled: exec_cfg.fetch("enabled", true) && !exec_tool.nil?,
                 allow_command: cron_cfg.fetch("allow_command", true),
                 command_allowed_remotes: cron_cfg["command_allowed_remotes"] || []),
    WebFetch.new(format: web_cfg["format"] || "plaintext",
                 proxy: web_cfg["proxy"],
                 fetch_limit_bytes: web_cfg["fetch_limit_bytes"],
                 private_host_whitelist: web_cfg["private_host_whitelist"] || []),
    # --- no-op scaffolds (no path args, no guards) ---
    FindSkills.new,
    InstallSkill.new,
    Spawn.new,
    Subagent.new,
    SpawnStatus.new,
  ]
end

# --- Workflow (built middleware-by-middleware) -------------------------------

def build_agent(config, session: "heartbeat")
  cron_store = CronStore.new(File.join(Dir.pwd, "cron", "jobs.json"))
  tool_list = build_tools(config, cron_store:)

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

  Brute.agent
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
    .use(ModelRouter)             # scaffold (no-op) — light/heavy pick
    .use(Media)                   # scaffold (no-op) — media:// store + resolver
    .use(SteeringLoop, mode: config["steering_mode"] || "one-at-a-time")
    .use(FallbackChain)           # scaffold (no-op) — candidates/cooldowns/RPM per LLM call
    .use(Subturns)                # scaffold (no-op) — spawn/subagent machinery + result drain
    .use(ToolPolicy)              # scaffold (no-op) — final home: per-tool-call layer
    .use(Brute::Middleware::MaxIterations)
    .use(Brute::Middleware::ToolPipeline, tools: tool_list)
    .use(EmergencyCompression, summary_path: summary_path,
                               tool_defs: advertised,
                               max_tokens: config["max_tokens"],
                               context_window: config["context_window"],
                               max_retries: config["max_llm_retries"] || 2,
                               backoff_secs: config["llm_retry_backoff_secs"] || 2)
    .run(Brute::Middleware::OpenRouter::Completion.new({}, **options))
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
