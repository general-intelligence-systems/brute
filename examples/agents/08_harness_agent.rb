#!/usr/bin/env ruby
# frozen_string_literal: true

# Harness agent — Brute as the substrate for a *harnessed* coding agent.
#
# "Harness engineering" (https://github.com/walkinglabs/learn-harness-engineering)
# says a reliable coding agent needs five subsystems. Brute already ships a
# primitive for each — this example wires them together so the mapping is
# explicit:
#
#   Subsystem     Harness role                         Brute primitive
#   ───────────   ──────────────────────────────────   ─────────────────────────
#   Instructions  startup path, rules, done-criteria    SystemPrompt + rules msg
#   State         current work, survives a restart      SessionLog (JSONL on disk)
#   Verification  the command that proves "done"        Shell tool running bin/test
#   Scope         what the agent may touch              curated tool set + MaxIterations
#   Lifecycle     resume the next session cleanly       SessionLog resume (run twice)
#
# The point isn't a new feature — it's that the harness is just *configuration*
# of the pipeline. Run it twice to watch Lifecycle + State do their job: the
# second run reloads the same JSONL log instead of starting cold.
#
# Defaults to a local Ollama (see docker-compose.yml). Override with env vars:
#   BRUTE_PROVIDER=anthropic BRUTE_MODEL=claude-sonnet-4-20250514 \
#     ANTHROPIC_API_KEY=... ruby examples/agents/08_harness_agent.rb

require_relative "helper"

PROVIDER     = ENV.fetch("BRUTE_PROVIDER", "ollama").to_sym
MODEL        = ENV.fetch("BRUTE_MODEL", "llama3.2")
SESSION_PATH = File.join(__dir__, "tmp", "session_08_harness.jsonl")

# ── Instructions ────────────────────────────────────────────────────────────
# The harness "AGENTS.md": routing + invariants + definition of done. Kept
# short on purpose — a router, not a manual. Here it travels *with* the agent
# as the first user message instead of living in a repo file.
HARNESS_RULES = <<~RULES
  You are a harnessed coding agent working inside the `brute` gem (a Ruby
  project: Ruby >= 3.3, tested with `scampi`, linted with `rubocop`).

  WORKING RULES
  - Ruby only. Every file starts with `# frozen_string_literal: true`.
  - Read before you write: inspect a file with the fs tools before editing it.
  - One task at a time. Do not expand scope beyond what was asked.

  VERIFICATION — DEFINITION OF DONE
  - A change is DONE only when `bin/test` exits 0. Writing the code is not done.
  - After any edit, run `bin/test` via the shell tool and read the output.
  - If it fails, fix it and re-run. Do not report success on a red suite.

  SCOPE
  - You may read, search, patch, and run shell commands in this repo only.
RULES

# ── Scope ───────────────────────────────────────────────────────────────────
# The tool set *is* the blast radius. A harnessed agent gets exactly what its
# job needs: read/search to understand, patch/write to change, shell to verify,
# todo tools to track its own plan. No net_fetch, no sub_agent — nothing this
# task doesn't call for. MaxIterations (in the stack) bounds runaway loops.
HARNESS_TOOLS = [
  Brute::Tools::FSRead,
  Brute::Tools::FSSearch,
  Brute::Tools::FSPatch,
  Brute::Tools::FSWrite,
  Brute::Tools::Shell,      # ← the verification gate: runs bin/test
  Brute::Tools::TodoWrite,
  Brute::Tools::TodoRead,
].freeze

agent = Brute.agent
  .use(Brute::Middleware::EventHandler, handler_class: TerminalOutput)
  # ── State + Lifecycle ───────────────────────────────────────────────────
  # SessionLog loads prior messages from the JSONL on the way in and persists
  # the whole turn on the way out. That single line is cross-session
  # continuity: kill the process mid-task, run again, and the agent resumes
  # with full context. State and Lifecycle, for free. (There is no Session
  # class — the log on disk *is* the session.)
  .use(Brute::Middleware::SessionLog, path: SESSION_PATH)
  .use(Brute::Middleware::SystemPrompt)          # ← Instructions (framing)
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::MaxIterations)          # ← Scope (bounds the loop)
  .use(Brute::Middleware::ToolPipeline, tools: HARNESS_TOOLS)
  .run do |env|
    # All LLM config lives here, in the call proc (see 01_basic_agent.rb).
    context = RubyLLM.context do |config|
      config.ollama_api_base   = ENV.fetch("OLLAMA_API_BASE", "http://localhost:11434/v1")
      config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
      config.openai_api_key    = ENV["OPENAI_API_KEY"]
    end

    model, provider = RubyLLM::Models.resolve(
      MODEL, provider: PROVIDER, assume_exists: true, config: context.config
    )

    response = provider.complete(
      env[:messages],
      tools:       Brute.rubyllm_tools(env[:tools]),
      temperature: 0.7,
      model:       model,
    )

    RubyLLM::MessageTransport.new(response).wrap_each do |message|
      env[:messages] << message
    end
  end

# First run vs resume is decided by whether the log already exists on disk —
# SessionLog reloads it either way; we just choose the prompt to append.
prompt =
  if File.exist?(SESSION_PATH)
    puts "=== Harness session (resumed) ← #{SESSION_PATH} ==="
    "Recap what you changed last session and confirm `bin/test` is still green."
  else
    puts "=== Harness session (fresh) → #{SESSION_PATH} ==="
    HARNESS_RULES + "\n\n" \
      "TASK: Add a `Brute::VERSION_SUMMARY` constant to lib/brute/version.rb " \
      "that returns \"brute \#{Brute::VERSION}\". Then prove it: run `bin/test` " \
      "and confirm the suite is green before you report done."
  end

env = agent.start(prompt)
print_events(env[:messages])
