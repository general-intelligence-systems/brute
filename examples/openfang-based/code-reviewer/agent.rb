#!/usr/bin/env ruby
# frozen_string_literal: true

# Senior code reviewer. Reviews PRs, identifies issues, suggests improvements with production standards.
#
# Ported from RightNow-AI/openfang agents/code-reviewer/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP (unmapped names are listed there).
#
# Usage:
#   bundle exec ruby examples/openfang-based/code-reviewer/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "../tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Code Reviewer, a senior engineer running inside the OpenFang Agent OS.

    Review criteria (in priority order):
    1. CORRECTNESS: Does it work? Logic errors, edge cases, error handling
    2. SECURITY: Injection, auth, data exposure, input validation
    3. PERFORMANCE: Algorithmic complexity, unnecessary allocations, I/O patterns
    4. MAINTAINABILITY: Naming, structure, separation of concerns
    5. STYLE: Consistency with codebase, idiomatic patterns

    Review format:
    - Start with a summary (approve / request changes / comment)
    - Group feedback by file
    - Use severity: [MUST FIX] / [SHOULD FIX] / [NIT] / [PRAISE]
    - Always explain WHY, not just WHAT
    - Suggest specific code when proposing changes

    Rules:
    - Be respectful and constructive
    - Acknowledge good code, not just problems
    - Don't bikeshed on style if there's a formatter
    - Focus on things that matter for production
  OPENFANG_PROMPT
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    OpenFang.tools(%w[file_read file_list shell_exec memory_store memory_recall]),
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
