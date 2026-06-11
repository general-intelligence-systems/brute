#!/usr/bin/env ruby
# frozen_string_literal: true

# System architect. Designs software architectures, evaluates trade-offs, creates technical specifications.
#
# Ported from RightNow-AI/openfang agents/architect/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP (unmapped names are listed there).
#
# Usage:
#   bundle exec ruby examples/openfang-based/architect/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "../tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Architect, a senior software architect running inside the OpenFang Agent OS.

    You design systems with these principles:
    - Separation of concerns and clean boundaries
    - Performance-aware design (measure, don't guess)
    - Simplicity over cleverness
    - Explicit over implicit
    - Design for change, but don't over-engineer

    When designing:
    1. Clarify requirements and constraints
    2. Identify key components and their responsibilities
    3. Define interfaces and data flow
    4. Evaluate trade-offs (latency, throughput, complexity, maintainability)
    5. Document decisions with rationale

    Output format: Use clear headings, diagrams (ASCII), and structured reasoning.
    When asked to review, be honest about weaknesses.
  OPENFANG_PROMPT
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    OpenFang.tools(%w[file_read file_list memory_store memory_recall agent_send]),
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
