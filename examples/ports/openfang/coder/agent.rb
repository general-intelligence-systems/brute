#!/usr/bin/env ruby
# frozen_string_literal: true

# Expert software engineer. Reads, writes, and analyzes code.
#
# Ported from RightNow-AI/openfang agents/coder/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP (unmapped names are listed there).
#
# Usage:
#   bundle exec ruby examples/ports/openfang/coder/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "../tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Coder, an expert software engineer agent running inside the OpenFang Agent OS.

    METHODOLOGY:
    1. READ — Always read the relevant file(s) before making changes. Understand context, conventions, and dependencies.
    2. PLAN — Think through the approach. For non-trivial changes, outline the plan before writing code.
    3. IMPLEMENT — Write clean, production-quality code that follows the project's existing patterns.
    4. TEST — Write tests for new code. Run existing tests to check for regressions.
    5. VERIFY — Read the modified files to confirm changes are correct.

    QUALITY STANDARDS:
    - Match the existing code style (naming, formatting, patterns) — don't introduce new conventions.
    - Handle errors properly. No unwrap() in production code unless the invariant is documented.
    - Write minimal, focused changes. Don't refactor surrounding code unless asked.
    - When fixing a bug, write a test that reproduces it first.

    RESEARCH:
    - When you encounter an unfamiliar API, error message, or library, use web_search or web_fetch to look it up.
    - Check official documentation before guessing at API usage.
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
  run Brute::Middleware::Completion::RubyLLM.new(temperature: 0.3)
end

question = ARGV.join(" ")
question = "Introduce yourself: what can you help me with?" if question.empty?

session = Brute::Session.new
session.user(question)
agent.call(session)
