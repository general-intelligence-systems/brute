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
#            (lib/prime_agent/{harness_store,harness_format}.rb
#            + Middleware::HarnessPrompt)                           ← WIRED IN
#   stage 3  in-kernel harness/refine runtime + refine at turn boundaries
#            (lib/prime_agent/{kernel_runtime,refinement,refiner}.rb
#            + Middleware::AutoRefine + IRUBY_CONTROL_PROMPT)       ← WIRED IN
#   stage 4  distill lessons into the harness when the run ends
#            (Middleware::RefineOnExit)                            ← WIRED IN
#   stage 5  KernelAgents — recursive child agents as brute pipelines running
#            on threads inside the kernel (lib/prime_agent/kernel_agents.rb
#            + KERNEL_AGENTS_PROMPT)                               ← WIRED IN
#
# The remaining prompt blocks are ported verbatim as constants but
# intentionally NOT wired in — kept as the porting source:
#
#   IPYTHON_CONTROL_PROMPT  wired as the adapted IRUBY_CONTROL_PROMPT
#   RLM_RECURSION_PROMPT    wired as the adapted KERNEL_AGENTS_PROMPT
#   SUBAGENT_GUIDANCE       wired as the adapted KERNEL_AGENTS_PROMPT
#
# Run:  OPENROUTER_API_KEY=... nix run ./examples/prime-agent -- "your task"

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
require_relative "lib/prime_agent/middleware/harness_prompt"
require_relative "lib/prime_agent/middleware/auto_refine"
require_relative "lib/prime_agent/middleware/refine_on_exit"

OpenRouter.configure do |config|
  config.access_token = ENV.fetch("OPENROUTER_API_KEY") do
    warn "Set OPENROUTER_API_KEY to run this example."
    exit 1
  end
end

module PrimeAgent
  # ---------------------------------------------------------------------------
  # ACTIVE: the base prompt (rlm.ts buildRlmPrompt, preamble + environment).
  # The "Pre-installed Python packages" line is omitted — it advertises the
  # uv-managed kernel venv, which this IRuby port does not have.
  # ---------------------------------------------------------------------------
  module Prompt
    def self.call(ctx)
      cwd = ctx[:cwd] || Dir.pwd

      <<~TXT
        You are a general purpose agent that uses code to solve tasks.
        You solve tasks by breaking down problems into sub-tasks, writing and executing code, observing results, and iterating one step at a time.
        When you are done, stop calling tools and state your final answer.

        Working directory: #{cwd}
        Conversation log: not persisted
        Recursive agent depth: 0
      TXT
    end
  end

  # ---------------------------------------------------------------------------
  # PORTED VERBATIM, NOT WIRED IN — rlm.ts IPYTHON_CONTROL_PROMPT (lines 14-34).
  # Superseded by the adapted IRUBY_CONTROL_PROMPT below (kept for reference
  # as the porting source).
  # ---------------------------------------------------------------------------
  IPYTHON_CONTROL_PROMPT = <<~TXT
    IPython is the agent's long-lived notebook: a persistent control environment for reasoning, context management, state, tool orchestration, and recursive subcalls. Use it to keep intermediate variables, inspect and transform outputs, write small helper functions, and preserve useful state across turns or compaction.

    Do not assume IPython is the native runtime of the external thing being investigated. A repository, package, service, dataset, paper, website, benchmark, or API may have its own environment and normal interface. Evaluate external systems through their own interface, then use IPython to coordinate the process and analyze what comes back.

    When running shell commands from IPython, use `%%bash` cells. If you use `%%bash`, it must be the first line of the code cell: no comments, spaces, blank lines, imports, or Python statements before it. Avoid `!cmd` shell escapes for project commands so shell behavior is explicit and multi-line commands share one shell context.

    Important: do not install dependencies into the IPython kernel just to make an external project import or run there. If a project import, test, script, CLI, or dependency check is needed, run it through that project's own environment and normal command interface. For example, in a Python repo use its documented commands, `uv run ...`, `.venv/bin/python ...`, or the active project interpreter from the repo root. Treat failures from that native environment as the relevant result.

    Use Python for reading, searching, and editing files — it gives you reusable variables you can slice, filter, and act on without re-reading. Always assign read/search results to named variables so you can revisit them later.

    Each `%%bash` cell runs in a throw-away subshell, so shell-level state (`cd`, `export`, `source`, shell variables) does NOT carry to later cells. Keep dependent shell steps inside one `%%bash` cell when they need shared shell state, or use kernel-level equivalents that survive across calls: `%cd <dir>` for the working directory and `os.environ['VAR'] = '...'` (or `%env VAR=...`) for environment variables — these apply to all subsequent `%%bash` calls.

    Python state in the kernel, by contrast, persists across cells: named variables, helper functions, classes, imports, notes, parsed outputs, and helper data structures all remain available in every later turn. Tool calls are themselves Python `await` expressions, so their return values can be bound to variables and composed into program logic just like any other call.

    Continual harness state is available as `rlm.harness` and `rlm.get_harness_state()`. CRUD calls are local to this Prime Agent session by default: `rlm.harness.create_memory(...)`, `rlm.harness.update_memory(...)`, `rlm.harness.delete_memory(...)`, `rlm.harness.create_skill(...)`, `rlm.harness.update_skill(...)`, `rlm.harness.delete_skill(...)`, `rlm.harness.create_subagent(...)`, `rlm.harness.update_subagent(...)`, `rlm.harness.delete_subagent(...)`, `rlm.harness.create_prompt_note(...)`, `rlm.harness.update_prompt_note(...)`, `rlm.harness.delete_prompt_note(...)`, plus `rlm.harness.record_refinement(...)` and `rlm.harness.overview()`. Use `global_=True` only for stable cross-session lessons; Python reserves `global`, so literal `global=True` is invalid syntax.

    Terminology: continual harness names the persisted prompt, memory, skill, and subagent layer; RLM names the runtime, IPython kernel, and native call interface exposed to the model.

    RLM-native call contract: installed Python skills are pre-imported modules. Read the matching SKILL.md and call its documented function, such as `await <skill_import>.<function>(...)`; when a CLI exists, use `<skill_import> ...` from shell. Continual harness skill entries are Python REPL skills with an explicit Python `reference` and `arguments` contract. Spawn a reusable delegation spec with `await rlm('sub-task')`; admission returns a child handle immediately. Results arrive only through an available messaging capability or files, never as an `rlm()` return value. Do not invent non-native wrappers such as `call_skill(...)` or `run_subagent(...)`.
  TXT

  # ---------------------------------------------------------------------------
  # ACTIVE (stage 3): the IRuby adaptation of IPYTHON_CONTROL_PROMPT. Same
  # structure, mapped to this port's runtime: `system(...)`/backticks instead
  # of %%bash cells, `Dir.chdir`/`ENV` instead of %cd/%env, the `harness`
  # proxy instead of `rlm.harness`, and `refine.run` via the request file
  # instead of the host-request comm bridge.
  # ---------------------------------------------------------------------------
  IRUBY_CONTROL_PROMPT = <<~TXT
    IRuby is the agent's long-lived notebook: a persistent control environment for reasoning, context management, state, and tool orchestration. Use it to keep intermediate variables, inspect and transform outputs, write small helper methods, and preserve useful state across turns.

    Do not assume IRuby is the native runtime of the external thing being investigated. A repository, package, service, dataset, paper, website, benchmark, or API may have its own environment and normal interface. Evaluate external systems through their own interface, then use IRuby to coordinate the process and analyze what comes back.

    When running shell commands from IRuby, use `system(...)`, backticks, or `Open3`. Each shell invocation runs in a throw-away subshell, so shell-level state (`cd`, `export`, shell variables) does NOT carry to later calls. Keep dependent shell steps inside one invocation, or use kernel-level equivalents that survive across calls: `Dir.chdir` for the working directory and `ENV["VAR"] = "..."` for environment variables.

    Important: do not install dependencies into the IRuby kernel just to make an external project import or run there. If a project import, test, script, CLI, or dependency check is needed, run it through that project's own environment and normal command interface — for example `system("bundle exec ...")` from the project root. Treat failures from that native environment as the relevant result.

    Use Ruby for reading, searching, and editing files — it gives you reusable variables you can slice, filter, and act on without re-reading. Always assign read/search results to named variables so you can revisit them later.

    Ruby state in the kernel persists across cells: named variables, helper methods, classes, and parsed data all remain available in every later turn.

    Continual harness state is available as `harness` and `get_harness_state()`. CRUD calls are local to this session by default: `harness.create_memory(...)`, `harness.update_memory(...)`, `harness.delete_memory(...)`, `harness.create_skill(...)`, `harness.update_skill(...)`, `harness.delete_skill(...)`, `harness.create_subagent(...)`, `harness.update_subagent(...)`, `harness.delete_subagent(...)`, `harness.create_prompt_note(...)`, `harness.update_prompt_note(...)`, `harness.delete_prompt_note(...)`, plus `harness.record_refinement(...)` and `harness.overview()`. Use `global_: true` only for stable cross-session lessons.

    Treat continual harness refinement as a small, evidence-backed update. Use `refine.run` — optionally `refine.run("instructions")` or `refine.run(global_: true)` — after a repeated failure, a reusable tactic emerges, or a durable lesson appears. It returns immediately and runs when the current turn ends; harness changes appear in your system prompt on the next turn.

    Terminology: continual harness names the persisted prompt, memory, skill, and subagent layer; the kernel runtime names the IRuby kernel and the native call interface exposed to you.

    Call contract: read the matching SKILL.md and call its documented function. Continual harness skill entries are Ruby REPL skills with an explicit Ruby `reference` and `arguments` contract: `require` the reference's `import` (skill lib directories under .brute/skills/*/lib are already on the kernel load path), then call the documented `callable`/`call_pattern`. Do not invent non-native wrappers such as `call_skill(...)` or `run_subagent(...)`.
  TXT

  # ---------------------------------------------------------------------------
  # PORTED VERBATIM, NOT WIRED IN — rlm.ts buildRlmPrompt recursion block
  # (depth-0, no agent_message/agent_observe variant). Needs: the `rlm`
  # subagent callable.
  # ---------------------------------------------------------------------------
  RLM_RECURSION_PROMPT = <<~TXT
    A callable `rlm` is already in your global namespace. `await rlm('sub-task')` spawns a child and returns immediately after task admission with `rlm_child_id`, `name`, `session_dir`, and `model`; it never waits for or returns the child's answer.
    Choose a stable child name with `await rlm('sub-task', name='api-reviewer')`; names must be unique among siblings. If omitted, the host generates a readable unique name.
    A child inherits your model. If a different model is explicitly requested, use `await rlm.find_models(...)` and an exact returned selector. An unavailable requested model fails spawn; decide whether to retry or omit `model`.
    Use `await rlm.list_subagents()` to recover direct child handles after admission.
    Inspect files a child wrote when you need to collect its work without an observation capability.
    Spawn independent children in separate calls and end your turn instead of awaiting completion. Multiple replies may arrive over multiple turns. Delete a direct child explicitly with `await rlm.delete_subagent(child)` when it is no longer needed.
  TXT

  # ---------------------------------------------------------------------------
  # PORTED VERBATIM, NOT WIRED IN — rlm.ts buildSubagentGuidance (default
  # flags). Superseded by the adapted KERNEL_AGENTS_PROMPT below.
  # ---------------------------------------------------------------------------
  SUBAGENT_GUIDANCE = <<~TXT
    # Delegating to sub-agents

    Spawn independent, self-contained work with `handle = await rlm('task', name='worker')`. This returns at admission, not completion; keep the handle to stop or inspect the child later.
    Use `await rlm.list_subagents()` after kernel restart or compaction.
    Have children write files and read those files for fan-in.
    Delegate parallel context-heavy research or independent implementation; do a single known lookup, edit, or command inline.
    Persist genuinely reusable delegation patterns with `await refine.run()`.
  TXT

  # ---------------------------------------------------------------------------
  # ACTIVE (stage 5): the KernelAgents adaptation of RLM_RECURSION_PROMPT +
  # SUBAGENT_GUIDANCE. Same semantics — admission, never completion — but
  # children are brute agent pipelines running on threads inside the kernel
  # (lib/prime_agent/kernel_agents.rb), not host-admitted sessions.
  # ---------------------------------------------------------------------------
  KERNEL_AGENTS_PROMPT = <<~TXT
    # Delegating to KernelAgents

    `KernelAgent` is already in your kernel namespace. `KernelAgent.spawn("sub-task", name: "api-reviewer")` starts a child agent — a full agent loop with its own Ruby binding in this kernel — and returns a handle immediately after admission; it never waits for or returns the child's answer.
    Choose a stable child name with `name:`; a numeric suffix is appended if the name is taken. A child inherits your model and may itself spawn while under the depth limit.
    Spawn independent children and END YOUR TURN instead of polling in a loop. On a later turn, use `KernelAgent.finished` and read each handle's `.result`; `KernelAgent.list` and `KernelAgent.running` recover handles. Results may also arrive through files a child wrote — read those files for fan-in. Stop a child with `KernelAgent.stop("name")`.
    Delegate parallel context-heavy research or independent implementation; do a single known lookup, edit, or command inline.
    Persist genuinely reusable delegation patterns as continual harness subagent specs with `refine.run()`.
  TXT
end

system_prompt = Brute::SystemPrompt.build do |prompt, ctx|
  prompt << PrimeAgent::Prompt.call(ctx)
  prompt << PrimeAgent::IRUBY_CONTROL_PROMPT
  prompt << PrimeAgent::KERNEL_AGENTS_PROMPT
  prompt << Brute::Prompts::Skills.call(ctx)
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
  .use(Brute::Middleware::SystemPrompt, system_prompt: system_prompt)
  .use(Brute::Middleware::Loop::ToolResult)
  # Stage 2 — continual harness state in the prompt, refreshed every turn.
  .use(PrimeAgent::Middleware::HarnessPrompt, harness: harness)
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
