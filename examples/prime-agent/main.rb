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
#   stage 9  goals + autonomous mode — the persistent thread goal
#            (Middleware::Goal + goal.json + the kernel's `goal` proxy) and
#            bounded continuations with quality gates
#            (Middleware::Autonomous + lib/prime_agent/autonomous.rb);
#            the goal gets first refusal every turn              ← WIRED IN
#   stage 10 the family bus — agent_message/agent_observe kernel proxies,
#            mailbox delivery at turn boundaries (Middleware::AgentMessages),
#            published transcripts (Middleware::AgentObserve), K3/K4 registry
#            completion; plus the <available_skills> block (M16) and the
#            prime-intellect/skill-creator doc skills (S4/S5)    ← WIRED IN
#   stage 11 MCP + models — Linear/Notion skills on the mcp gem client with
#            shared auth.json credentials (lib/prime_agent/mcp.rb) + OAuth
#            login helper (mcp_login.rb); KernelAgent.find_models on the
#            OpenRouter catalog (lib/prime_agent/model_registry.rb)
#                                                              ← WIRED IN
#   stage 12 the deferred substrate — usage attribution (M18), kernel
#            snapshots (M17), attach-image (S3), session tree + branch
#            summaries (M9), side questions (M8), orphan reaper (M20)
#                                                              ← WIRED IN
#   All stages wired. FEATURES.md records the few deliberate divergences
#   (no daemon/TUI, steer delivery, driver-model scheduling).
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

require "securerandom"
require "time"
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
require_relative "lib/prime_agent/goal"
require_relative "lib/prime_agent/autonomous"
require_relative "lib/prime_agent/agent_family"
require_relative "lib/prime_agent/skills_block"
require_relative "lib/prime_agent/side_question"
require_relative "lib/prime_agent/middleware/agent_messages"
require_relative "lib/prime_agent/middleware/agent_observe"
require_relative "lib/prime_agent/middleware/autonomous"
require_relative "lib/prime_agent/middleware/compaction"
require_relative "lib/prime_agent/middleware/goal"
require_relative "lib/prime_agent/mcp"
require_relative "lib/prime_agent/model_registry"
require_relative "lib/prime_agent/middleware/orphan_reaper"
require_relative "lib/prime_agent/middleware/result_caps"
require_relative "lib/prime_agent/middleware/attach_images"
require_relative "lib/prime_agent/middleware/session_tree"
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
  # Stage 10 (M16) — the upstream-shaped <available_skills> block with
  # type/ruby_import fields (prime-agent's formatSkillsForPrompt).
  skills: ->(ctx) { PrimeAgent::SkillsBlock.call(cwd: ctx[:cwd] || Dir.pwd) },
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

# Stage 9 — the thread goal seed (upstream's `/goal <objective>` /
# `--goal --goal-token-budget`): the Goal middleware re-prompts until the
# kernel's `goal.complete` lands.
if ENV["BRUTE_GOAL"]
  PrimeAgent::Goal.create_in_store(
    File.join(refiner.local_dir, "goal.json"),
    objective: ENV["BRUTE_GOAL"],
    token_budget: ENV["BRUTE_GOAL_TOKEN_BUDGET"]&.to_i,
  )
end

# Autonomous gates: a single command string, or a JSON array of commands.
autonomous_gates =
  case (raw_gates = ENV["BRUTE_AUTONOMOUS_GATES"].to_s.strip)
  when "" then []
  when /\A\[/ then JSON.parse(raw_gates)
  else [raw_gates]
  end

# One pipeline per run: each scheduled job gets a fresh kernel and fresh
# middleware state; the harness/cron stores persist across runs via files.
build_agent = lambda do
  # Stage 1+3 — the kernel boots lazily on the model's first iruby call; the
  # bootstrap cell loads the harness/refine runtime into the kernel namespace.
  # Stage 12 (M17) — the namespace snapshots to disk (debounced after ok
  # cells + a final flush at shutdown) and restores at the next run's boot.
  snapshot_path = unless ENV["BRUTE_KERNEL_SNAPSHOT"] == "0"
                    File.join(refiner.local_dir, "kernel_snapshot.marshal")
                  end
  provisioner = PrimeAgent::KernelProvisioner.new(
    cwd: Dir.pwd,
    snapshot_path: snapshot_path,
    # callable: the snapshot is read and codegen'd at boot time (lazy first tool
    # call), not at pipeline build time
    bootstrap: -> {
      PrimeAgent::KernelRuntime.bootstrap_code(
        harness_store_path: File.expand_path("lib/prime_agent/harness_store.rb", __dir__),
        local_dir: refiner.local_dir,
        global_dir: refiner.global_dir,
        request_path: refiner.request_path,
        skill_lib_glob: File.join(Dir.pwd, ".brute", "skills", "*", "lib"),
        snapshot_path: snapshot_path,
      )
    },
  )

  Brute.agent
    # ── run lifecycle ──────────────────────────────────────────────────
    # Stage 1 — kernel lifecycle: shut the IRuby kernel down when the run ends.
    .use(PrimeAgent::Middleware::KernelLifecycle, provisioner: provisioner)
    # Stage 12 — reap kernel-spawned orphan processes at run end (M20):
    # journaled by the kernel's Process.spawn wrapper, group-SIGKILLed with
    # start-time identity checks so recycled pids are never killed.
    .use(PrimeAgent::Middleware::OrphanReaper,
         journal_path: File.join(refiner.local_dir, "orphans.jsonl"))
    # (M17 lives in the provisioner: snapshot/restore of the kernel namespace
    # — no turn-pipeline work. See KernelProvisioner.)
    # Stage 4 — distill lessons into the harness when the run ends, so one-shot
    # and scheduled (systemd timer) runs learn across runs.
    # Disable with BRUTE_REFINE_FINAL=0.
    .use(PrimeAgent::Middleware::RefineOnExit, refiner: refiner)
    # ── per-turn services & continuation drivers (scaffolds) ─────────────
    # Stage 12 — session tree (M9): journal every message to a per-run JSONL
    # log with id/parent linkage; BRUTE_FORK=<log>[#<entry>] forks a new run
    # from a prior one and injects the abandoned tail's branch summary.
    .use(PrimeAgent::Middleware::SessionTree,
         llm: refine_llm,
         log_path: File.join(Dir.pwd, ".brute", "sessions",
                             "#{Time.now.utc.strftime("%Y%m%d%H%M%S")}-#{SecureRandom.hex(4)}.jsonl"),
         fork_from: ENV["BRUTE_FORK"],
         context_window: ENV["BRUTE_CONTEXT_WINDOW"]&.to_i)
    # Stage 9 — the persistent thread goal (M2): re-prompts with the goal
    # context after every turn until the kernel's goal.complete lands, the
    # budget flips it, or an error marks it. Outer of Autonomous: the goal
    # gets first refusal every turn.
    .use(PrimeAgent::Middleware::Goal,
         store_path: File.join(refiner.local_dir, "goal.json"),
         request_path: File.join(refiner.local_dir, "goal_request.json"))
    # Stage 9 — autonomous mode (M3): bounded continuations + quality gates
    # (BRUTE_AUTONOMOUS=1, BRUTE_AUTONOMOUS_GATES). Defers while a goal is active.
    .use(PrimeAgent::Middleware::Autonomous,
         enabled: ENV["BRUTE_AUTONOMOUS"] == "1",
         cwd: Dir.pwd,
         goal_store_path: File.join(refiner.local_dir, "goal.json"),
         gates: autonomous_gates,
         max_continuations: ENV["BRUTE_AUTONOMOUS_MAX_CONTINUATIONS"]&.to_i,
         max_turns: ENV["BRUTE_AUTONOMOUS_MAX_TURNS"]&.to_i,
         max_tokens: ENV["BRUTE_AUTONOMOUS_MAX_TOKENS"]&.to_i,
         timeout_ms: ENV["BRUTE_AUTONOMOUS_TIMEOUT_MS"]&.to_i)
    # Stage 10 — the family bus (M6/M7): drain this run's mailbox into the
    # conversation at every turn boundary, then publish the transcript for
    # agent_observe. (M10's queue lanes are subsumed by the ScheduleDriver +
    # this drain; M16's <available_skills> block lives in prompts/system.erb
    # via PrimeAgent::SkillsBlock.)
    .use(PrimeAgent::Middleware::AgentMessages,
         bus_dir: File.join(refiner.local_dir, "agent_bus"), agent_id: "root")
    .use(PrimeAgent::Middleware::AgentObserve,
         bus_dir: File.join(refiner.local_dir, "agent_bus"), agent_id: "root")
    # ── the loop ───────────────────────────────────────────────────────
    .use(Brute::Middleware::Loop::ToolResult)
    # ── per-iteration ──────────────────────────────────────────────────
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
    # Stage 12 — usage accounting (M18): accumulate the provider's per-call
    # usage into env metadata (goal budgets, autonomous limits, compaction
    # thresholds read it) and publish the family usage tree.
    .use(PrimeAgent::Middleware::UsageAttribution,
         bus_dir: File.join(refiner.local_dir, "agent_bus"), agent_id: "root")
    # Stage 6 — tool-result caps (M11): tail-truncate at 2000 lines / 50 KB,
    # first cap to fire wins (M12, same-file mutation serialization, lives
    # kernel-side in the edit skill's MutationQueue — mutations happen in the
    # kernel, not the tool pipeline).
    .use(PrimeAgent::Middleware::ResultCaps)
    # Stage 12 — attached images (S3) become model-visible user messages.
    .use(PrimeAgent::Middleware::AttachImages, provisioner: provisioner)
    # Stage 1 — the persistent IRuby kernel as the single model-facing tool
    # (prime-agent's "everything is programmatic" one-tool design).
    .use(Brute::Middleware::ToolPipeline, tools: [PrimeAgent::IrubyTool.new(provisioner: provisioner)])
    .run(Brute::Middleware::OpenRouter::Completion.new({}, **options))
end

task = ARGV.empty? ? "What files are in the current directory? List them." : ARGV.join(" ")
env = PrimeAgent::ScheduleDriver.new(store: store, agent_factory: build_agent)
                                .run(task, follow: ENV["BRUTE_FOLLOW"] == "1")
puts env[:messages].reverse.find { |message| message.role == :assistant }&.content

# Stage 12 (M8) — the /btw side question: a one-off question against the
# finished run's conversation, on a clone with no tools (nothing is added to
# the main session).
if ENV["BRUTE_BTW"]
  answer, = PrimeAgent::SideQuestion.ask(
    messages: env[:messages],
    question: ENV["BRUTE_BTW"],
    terminal: Brute::Middleware::OpenRouter::Completion.new({}, **options),
  )
  puts answer
end
