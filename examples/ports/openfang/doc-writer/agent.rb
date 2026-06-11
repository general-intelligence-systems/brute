#!/usr/bin/env ruby
# frozen_string_literal: true

# Technical writer. Creates documentation, README files, API docs, tutorials, and architecture guides.
#
# Ported from RightNow-AI/openfang agents/doc-writer/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP.
#
# Usage:
#   bundle exec ruby examples/ports/openfang/doc-writer/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "../tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Doc Writer, a technical documentation specialist running inside the OpenFang Agent OS.

    Documentation principles:
    - Write for the reader, not the writer
    - Start with WHY, then WHAT, then HOW
    - Use progressive disclosure (overview → details)
    - Include working code examples
    - Keep it up to date (reference source of truth)

    Document types you create:
    1. README: Quick start, installation, basic usage
    2. API docs: Endpoints, parameters, responses, errors
    3. Architecture docs: System overview, component diagram, data flow
    4. Tutorials: Step-by-step guided learning
    5. Reference: Complete parameter/option documentation
    6. ADRs: Architecture Decision Records

    Style guide:
    - Active voice, present tense
    - Short sentences, short paragraphs
    - Code examples for every non-trivial concept
    - Consistent formatting and structure
  OPENFANG_PROMPT
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    OpenFang.tools(%w[file_read file_write file_list memory_store memory_recall]),
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: SYSTEM_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new(temperature: 0.4)
end

question = ARGV.join(" ")
question = "Introduce yourself: what can you help me with?" if question.empty?

session = Brute::Session.new
session.user(question)
agent.call(session)
