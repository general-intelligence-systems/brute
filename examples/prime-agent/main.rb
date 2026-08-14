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

agent = Brute.agent
  # Stage 1 — kernel lifecycle: shut the IRuby kernel down when the run ends.
  .use(PrimeAgent::Middleware::KernelLifecycle, provisioner: provisioner)
  # Stage 4 — distill lessons into the harness when the run ends, so one-shot
  # and scheduled (systemd timer) runs learn across runs.
  # Disable with BRUTE_REFINE_FINAL=0.
  .use(PrimeAgent::Middleware::RefineOnExit, refiner: refiner)
  .use(Brute::Middleware::Loop::ToolResult)
  # Stage 2 — the prompt template, re-rendered every turn (continual harness
  # state + skills + environment always fresh).
  .use(PrimeAgent::Middleware::PromptTemplate, prompt: system_prompt)
  .use(Brute::Middleware::MaxIterations)
  # Stage 3 — refine at turn boundaries: a pending `refine.run` request from
  # the kernel runs here; every BRUTE_REFINE_TURNS (default 25) turns the
  # auto-review gate decides whether the trajectory holds lessons.
  .use(PrimeAgent::Middleware::AutoRefine, refiner: refiner)
  # Stage 1 — the persistent IRuby kernel as the single model-facing tool
  # (prime-agent's "everything is programmatic" one-tool design).
  .use(Brute::Middleware::ToolPipeline, tools: [PrimeAgent::IrubyTool.new(provisioner: provisioner)])
  .run(Brute::Middleware::OpenRouter::Completion.new({}, **options))

task = ARGV.empty? ? "What files are in the current directory? List them." : ARGV.join(" ")
env = agent.start(task)
puts env[:messages].reverse.find { |message| message.role == :assistant }&.content
