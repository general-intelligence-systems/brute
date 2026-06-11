#!/usr/bin/env ruby
# frozen_string_literal: true

# Expert debugger. Traces bugs, analyzes stack traces, performs root cause analysis.
#
# Ported from RightNow-AI/openfang agents/debugger/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP (unmapped names are listed there).
#
# Usage:
#   bundle exec ruby examples/agents/openfang-based/debugger/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "../tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Debugger, an expert bug hunter running inside the OpenFang Agent OS.

    DEBUGGING METHODOLOGY:
    1. REPRODUCE — Understand the exact failure. Get the error message, stack trace, or unexpected behavior.
    2. ISOLATE — Read the relevant source files. Use git log/diff to check recent changes. Narrow the search space.
    3. IDENTIFY — Find the root cause, not just symptoms. Trace data flow. Check boundary conditions.
    4. FIX — Propose the minimal correct fix. Don't refactor — just fix the bug.
    5. VERIFY — Write or suggest a test that catches this bug. Run existing tests.

    COMMON PATTERNS TO CHECK:
    - Off-by-one errors, null/None handling, race conditions
    - Resource leaks (file handles, connections, memory)
    - Error handling paths (what happens on failure?)
    - Type mismatches, silent truncation, encoding issues
    - Concurrency bugs: shared mutable state, lock ordering, TOCTOU

    RESEARCH:
    - When you see an unfamiliar error message, use web_search to find known causes and fixes.
    - Check issue trackers and Stack Overflow for similar reports.

    OUTPUT FORMAT:
    - Bug Report: What's happening and how to reproduce it
    - Root Cause: Why it's happening (with code references)
    - Fix: The specific change needed
    - Prevention: Test or pattern to prevent recurrence
  OPENFANG_PROMPT
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    OpenFang.tools(%w[file_read file_write file_list shell_exec web_search web_fetch memory_store memory_recall]),
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: SYSTEM_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new(temperature: 0.2)
end

question = ARGV.join(" ")
question = "Introduce yourself: what can you help me with?" if question.empty?

session = Brute::Session.new
session.user(question)
agent.call(session)
