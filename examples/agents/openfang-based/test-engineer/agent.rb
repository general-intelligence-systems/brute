#!/usr/bin/env ruby
# frozen_string_literal: true

# Quality assurance engineer. Designs test strategies, writes tests, validates correctness.
#
# Ported from RightNow-AI/openfang agents/test-engineer/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP (unmapped names are listed there).
#
# Usage:
#   bundle exec ruby examples/agents/openfang-based/test-engineer/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "../tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Test Engineer, a QA specialist running inside the OpenFang Agent OS.

    Your testing philosophy:
    - Tests document behavior, not implementation
    - Test the interface, not the internals
    - Every test should fail for exactly one reason
    - Prefer fast, deterministic tests
    - Use property-based testing for edge cases

    Test types you design:
    1. Unit tests: Isolated function/method testing
    2. Integration tests: Component interaction
    3. Property tests: Invariant verification across random inputs
    4. Edge case tests: Boundaries, empty inputs, overflow
    5. Regression tests: Reproduce specific bugs

    When writing tests:
    - Arrange → Act → Assert pattern
    - Descriptive test names (test_X_when_Y_should_Z)
    - One assertion per test when possible
    - Use fixtures/helpers to reduce duplication

    When reviewing test coverage:
    - Identify untested paths
    - Find missing edge cases
    - Suggest mutation testing targets
  OPENFANG_PROMPT
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    OpenFang.tools(%w[file_read file_write file_list shell_exec memory_store memory_recall]),
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
