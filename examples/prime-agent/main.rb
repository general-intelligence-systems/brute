#!/usr/bin/env ruby
# frozen_string_literal: true

# prime-agent — https://github.com/PrimeIntellect-ai/prime-agent — ported to brute.
#
# The system prompt is a faithful port of prime-agent's buildSystemPrompt
# (packages/coding-agent/src/core/system-prompt.ts) and buildRlmPrompt
# (packages/coding-agent/src/core/prompts/rlm.ts).
#
# The ACTIVE prompt today covers the identity/loop preamble, the environment
# block, and the skills section (brute's Brute::Prompts::Skills, which discovers
# .brute/skills under the working directory — see work/). The remaining prompt
# blocks are ported verbatim as constants but intentionally NOT wired in yet —
# they document the features to port next:
#
#   IPYTHON_CONTROL_PROMPT  needs a persistent IPython kernel tool
#   RLM_RECURSION_PROMPT    needs the `rlm` subagent callable
#   SUBAGENT_GUIDANCE       needs rlm + the agent_message/agent_observe skills
#   (harness-state block)   needs the continual harness (rlm.harness CRUD)
#
# Run:  OPENROUTER_API_KEY=... nix run ./examples/prime-agent -- "your task"

require "open_router"
require "brute"

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
  # uv-managed kernel venv, which arrives with the IPython tool port.
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
  # Needs: persistent IPython kernel tool (with %%bash cells and a uv venv).
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
  # flags). Needs: rlm + the refine skill.
  # ---------------------------------------------------------------------------
  SUBAGENT_GUIDANCE = <<~TXT
    # Delegating to sub-agents

    Spawn independent, self-contained work with `handle = await rlm('task', name='worker')`. This returns at admission, not completion; keep the handle to stop or inspect the child later.
    Use `await rlm.list_subagents()` after kernel restart or compaction.
    Have children write files and read those files for fan-in.
    Delegate parallel context-heavy research or independent implementation; do a single known lookup, edit, or command inline.
    Persist genuinely reusable delegation patterns with `await refine.run()`.
  TXT
end

system_prompt = Brute::SystemPrompt.build do |prompt, ctx|
  prompt << PrimeAgent::Prompt.call(ctx)
  prompt << Brute::Prompts::Skills.call(ctx)
end

options = {}
options[:model] = ENV["BRUTE_MODEL"] if ENV["BRUTE_MODEL"]

agent = Brute.agent
  .use(Brute::Middleware::SystemPrompt, system_prompt: system_prompt)
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::MaxIterations)
  .use(Brute::Middleware::ToolPipeline, tools: Brute::Tools::ALL)
  .run(Brute::Middleware::OpenRouter::Completion.new({}, **options))

task = ARGV.empty? ? "What files are in the current directory? List them." : ARGV.join(" ")
puts agent.start(task)
