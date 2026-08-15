#!/usr/bin/env ruby
# frozen_string_literal: true

# prime-agent — https://github.com/PrimeIntellect-ai/prime-agent — ported to brute.
#
# The system prompt is a faithful port of prime-agent's buildSystemPrompt
# (packages/coding-agent/src/core/system-prompt.ts) and buildRlmPrompt
# (packages/coding-agent/src/core/prompts/rlm.ts).
#
# The port is built up stage by stage — every feature is a middleware:
#
#   stage 1  persistent IRuby kernel as the single model-facing tool
#            (lib/prime_agent/{jupyter,kernel_manager,kernel_provisioner,
#            iruby_tool}.rb + Middleware::KernelLifecycle)          ← WIRED IN
#   stage 2  continual harness state in the prompt (rlm.harness CRUD store)
#            (lib/prime_agent/{harness_store,harness_format,prompts}.rb
#            + Middleware::PromptTemplate + prompts/system.erb)     ← WIRED IN
#   stage 3  in-kernel harness/refine runtime + refine at turn boundaries
#            (lib/prime_agent/{kernel_runtime,refinement,refiner}.rb
#            + Middleware::AutoRefine)                              ← WIRED IN
#   stage 4  distill lessons into the harness when the run ends
#            (Middleware::RefineOnExit)                            ← WIRED IN
#   stage 5  KernelAgents — recursive child agents as brute pipelines running
#            on threads inside the kernel (lib/prime_agent/kernel_agents.rb
#            + prompts/kernel_agent.erb)                            ← WIRED IN
#   stage 6  kernel-pure skills + tool caps (edit with per-file mutation
#            queue + diff display, websearch; ResultCaps)          ← WIRED IN
#   stage 7  compaction — threshold/overflow/requested triggers, cut-point
#            selection, summary/update/turn-prefix prompts, file tracking
#            (lib/prime_agent/compaction.rb + Middleware::Compaction
#            + the kernel's `compact` proxy)                       ← WIRED IN
#   stage 8  scheduled prompts + heartbeats — the cron job store with
#            claim-ledger crash semantics (lib/prime_agent/cron_store.rb),
#            delivered as fresh runs by the ScheduleDriver (no resident
#            session to steer into); the kernel's `rlm_heartbeat` proxy
#            writes the store directly                           ← WIRED IN
#   stages 9+  the remaining 13 middlewares are SCAFFOLDS (pass-through
#            no-ops wired in their intended fill-in order) and the remaining
#            kernel skills are no-op stubs under work/.brute/skills/.
#            Fill in per FEATURES.md §5.
#
# All prompt text lives in prompts/*.erb — the system prompt is
# prompts/system.erb (driven by a Brute::PromptTemplate whose dynamic
# sections are procs re-rendered every turn by Middleware::PromptTemplate).
# prime-agent's original prompt blocks are kept verbatim under
# prompts/upstream/ as the annotated porting source:
#
#   ipython_control_prompt.txt  → the IRuby control prose in system.erb
#   rlm_recursion_prompt.txt    → the KernelAgents prose in system.erb
#   subagent_guidance.txt       → the KernelAgents prose in system.erb
#
# Run:  OPENROUTER_API_KEY=... nix run ./examples/prime-agent -- "your task"

# Inside the brute repo, prefer the checkout over the installed gem — this
# example drives Brute::PromptTemplate, which predates the next release.
repo_lib = File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift(repo_lib) if File.directory?(File.join(repo_lib, "brute"))

require "open_router"
require "brute"

require_relative "lib/prime_agent/jupyter"
require_relative "lib/prime_agent/kernel_manager"
require_relative "lib/prime_agent/kernel_provisioner"
require_relative "lib/prime_agent/iruby_tool"
require_relative "lib/prime_agent/harness_store"
require_relative "lib/prime_agent/harness_format"
require_relative "lib/prime_agent/kernel_runtime"
require_relative "lib/prime_agent/refinement"
require_relative "lib/prime_agent/refiner"
require_relative "lib/prime_agent/middleware/kernel_lifecycle"
require_relative "lib/prime_agent/middleware/prompt_template"
require_relative "lib/prime_agent/middleware/auto_refine"
require_relative "lib/prime_agent/middleware/refine_on_exit"

# Stage 6+ scaffolds — pass-through no-ops; see FEATURES.md §4 for what each
# fills in and upstream source refs.
require_relative "lib/prime_agent/cron_store"
require_relative "lib/prime_agent/schedule_driver"
require_relative "lib/prime_agent/middleware/agent_messages"
require_relative "lib/prime_agent/middleware/agent_observe"
require_relative "lib/prime_agent/middleware/autonomous"
require_relative "lib/prime_agent/middleware/compaction"
require_relative "lib/prime_agent/middleware/goal"
require_relative "lib/prime_agent/middleware/kernel_snapshot"
require_relative "lib/prime_agent/middleware/mcp_manager"
require_relative "lib/prime_agent/middleware/model_registry"
require_relative "lib/prime_agent/middleware/orphan_reaper"
require_relative "lib/prime_agent/middleware/prompt_queue"
require_relative "lib/prime_agent/middleware/result_caps"
require_relative "lib/prime_agent/middleware/session_tree"
require_relative "lib/prime_agent/middleware/side_question"
require_relative "lib/prime_agent/middleware/skills_xml"
require_relative "lib/prime_agent/middleware/usage_attribution"

OpenRouter.configure do |config|
  config.access_token = ENV.fetch("OPENROUTER_API_KEY") do
    warn "Set OPENROUTER_API_KEY to run this example."
    exit 1
  end
end

options = {}
options[:model] = ENV["BRUTE_MODEL"] if ENV["BRUTE_MODEL"]

# Stage 2 — the continual harness: session-local state under the working
# directory (.brute/harness), cross-session state under the home directory.
harness = PrimeAgent::Harness.new(
  local_store: PrimeAgent::HarnessStore.new(File.join(Dir.pwd, ".brute", "harness"), scope: "local"),
  global_store: PrimeAgent::HarnessStore.new(
    ENV["BRUTE_GLOBAL_HARNESS_DIR"] || File.join(Dir.home, ".brute", "harness"), scope: "global"
  ),
)

# Stage 3 — the refine loop. The review/plan passes call the same provider
# as the agent loop; the refinement request is deliberately non-streaming
# and JSON-only.
refine_llm = lambda do |system:, user:, max_tokens:|
  completion_options = { max_tokens: max_tokens }
  completion_options[:model] = ENV["BRUTE_MODEL"] if ENV["BRUTE_MODEL"]
  response = OpenRouter::Client.new.complete(
    [{ role: "system", content: system }, { role: "user", content: user }],
    OpenRouter::CompletionOptions.new(**completion_options),
  )
  response.choices.first["message"]["content"].to_s
end
refiner = PrimeAgent::Refiner.new(harness: harness, llm: refine_llm)

# The system prompt is a Brute::PromptTemplate over prompt.erb. The dynamic
# sections are procs re-evaluated on every render — Middleware::PromptTemplate
# re-renders every turn, so harness writes (kernel CRUD or refine edits) and
# newly dropped-in skills appear mid-run, and prompt.erb itself hot-reloads.
system_prompt = Brute::PromptTemplate.new(
  File.expand_path("prompts/system.erb", __dir__),
  cwd: ->(ctx) { ctx[:cwd] || Dir.pwd },
  harness_state: -> { PrimeAgent::HarnessFormat.format_harness_state_for_prompt(harness.merged_state) },
  skills: ->(ctx) { Brute::Prompts::Skills.call(ctx) },
)

# Stage 8 — scheduled prompts + heartbeats (M4/M5): the job store lives under
# the local harness dir; a due job is delivered as a FRESH agent run (there
# is no resident session to steer into — FEATURES.md M4/M5). The kernel's
# rlm_heartbeat proxy writes the same store directly.
store = PrimeAgent::CronStore.new(File.join(refiner.local_dir, "scheduled-jobs.json"))

# The user heartbeat (upstream's `/heartbeat every <interval> <instruction>`):
# a singleton recurring instruction, seeded from the environment in this
# no-TUI port.
if ENV["BRUTE_HEARTBEAT"]
  store.create_heartbeat(
    instruction: ENV["BRUTE_HEARTBEAT"],
    schedule_text: ENV["BRUTE_HEARTBEAT_EVERY"] || "every 5m",
  )
end

# One pipeline per run: each scheduled job gets a fresh kernel and fresh
# middleware state; the harness/cron stores persist across runs via files.
build_agent = lambda do
  # Stage 1+3 — the kernel boots lazily on the model's first iruby call; the
  # bootstrap cell loads the harness/refine runtime into the kernel namespace.
  provisioner = PrimeAgent::KernelProvisioner.new(
    cwd: Dir.pwd,
    bootstrap: PrimeAgent::KernelRuntime.bootstrap_code(
      harness_store_path: File.expand_path("lib/prime_agent/harness_store.rb", __dir__),
      local_dir: refiner.local_dir,
      global_dir: refiner.global_dir,
      request_path: refiner.request_path,
      skill_lib_glob: File.join(Dir.pwd, ".brute", "skills", "*", "lib"),
    ),
  )

  Brute.agent
    # ── run lifecycle ──────────────────────────────────────────────────
    # Stage 1 — kernel lifecycle: shut the IRuby kernel down when the run ends.
    .use(PrimeAgent::Middleware::KernelLifecycle, provisioner: provisioner)
    # SCAFFOLD — reap detached background processes at run end (FEATURES.md M20).
    .use(PrimeAgent::Middleware::OrphanReaper)
    # SCAFFOLD — kernel namespace snapshot/restore for session resume (M17).
    .use(PrimeAgent::Middleware::KernelSnapshot)
    # Stage 4 — distill lessons into the harness when the run ends, so one-shot
    # and scheduled (systemd timer) runs learn across runs.
    # Disable with BRUTE_REFINE_FINAL=0.
    .use(PrimeAgent::Middleware::RefineOnExit, refiner: refiner)
    # ── per-turn services & continuation drivers (scaffolds) ─────────────
    .use(PrimeAgent::Middleware::SessionTree)      # SCAFFOLD — fork/clone/navigate (M9)
    .use(PrimeAgent::Middleware::SideQuestion)     # SCAFFOLD — /btw one-turn clone (M8)
    .use(PrimeAgent::Middleware::McpManager)       # SCAFFOLD — MCP OAuth + catalog (M13)
    .use(PrimeAgent::Middleware::ModelRegistry)    # SCAFFOLD — find_models backend (M14)
    .use(PrimeAgent::Middleware::AgentObserve)     # SCAFFOLD — read-only family views (M7)
    .use(PrimeAgent::Middleware::AgentMessages)    # SCAFFOLD — family bus, steer-only (M6)
    .use(PrimeAgent::Middleware::Goal)             # SCAFFOLD — persistent goal re-prompt (M2)
    .use(PrimeAgent::Middleware::Autonomous)       # SCAFFOLD — continuations + gates (M3)
    # SCAFFOLD — steer/follow_up lanes + queue-key coalescing (M10); innermost
    # per-turn driver: everything above enqueues here.
    .use(PrimeAgent::Middleware::PromptQueue)
    # ── the loop ───────────────────────────────────────────────────────
    .use(Brute::Middleware::Loop::ToolResult)
    # ── per-iteration ──────────────────────────────────────────────────
    # SCAFFOLD — <available_skills> block + skill-command expansion (M16).
    .use(PrimeAgent::Middleware::SkillsXml)
    # Stage 2 — the prompt template, re-rendered every turn (continual harness
    # state + skills + environment always fresh).
    .use(PrimeAgent::Middleware::PromptTemplate, prompt: system_prompt)
    .use(Brute::Middleware::MaxIterations)
    # Stage 7 — compaction (M1): threshold (needs BRUTE_CONTEXT_WINDOW),
    # overflow-retry-once, and kernel-requested compaction at turn boundaries;
    # `compact.run`/`compact.status` in the kernel ride the request/status
    # files under the local harness dir.
    .use(PrimeAgent::Middleware::Compaction,
         llm: refine_llm,
         context_window: ENV["BRUTE_CONTEXT_WINDOW"]&.to_i,
         request_path: File.join(refiner.local_dir, "compact_request.json"),
         status_path: File.join(refiner.local_dir, "compact_status.json"))
    # Stage 3 — refine at turn boundaries: a pending `refine.run` request from
    # the kernel runs here; every BRUTE_REFINE_TURNS (default 25) turns the
    # auto-review gate decides whether the trajectory holds lessons.
    .use(PrimeAgent::Middleware::AutoRefine, refiner: refiner)
    # SCAFFOLD — token accounting + child attribution (M18).
    .use(PrimeAgent::Middleware::UsageAttribution)
    # Stage 6 — tool-result caps (M11): tail-truncate at 2000 lines / 50 KB,
    # first cap to fire wins (M12, same-file mutation serialization, lives
    # kernel-side in the edit skill's MutationQueue — mutations happen in the
    # kernel, not the tool pipeline).
    .use(PrimeAgent::Middleware::ResultCaps)
    # Stage 1 — the persistent IRuby kernel as the single model-facing tool
    # (prime-agent's "everything is programmatic" one-tool design).
    .use(Brute::Middleware::ToolPipeline, tools: [PrimeAgent::IrubyTool.new(provisioner: provisioner)])
    .run(Brute::Middleware::OpenRouter::Completion.new({}, **options))
end

task = ARGV.empty? ? "What files are in the current directory? List them." : ARGV.join(" ")
env = PrimeAgent::ScheduleDriver.new(store: store, agent_factory: build_agent)
                                .run(task, follow: ENV["BRUTE_FOLLOW"] == "1")
puts env[:messages].reverse.find { |message| message.role == :assistant }&.content
