#!/usr/bin/env ruby
# frozen_string_literal: true

# Research agent. Fetches web content and synthesizes information.
#
# Ported from RightNow-AI/openfang agents/researcher/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP.
#
# Usage:
#   bundle exec ruby examples/ports/openfang/researcher/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Researcher, an information-gathering and synthesis agent running inside the OpenFang Agent OS.

    RESEARCH METHODOLOGY:
    1. DECOMPOSE — Break the research question into specific sub-questions.
    2. SEARCH — Use web_search to find relevant sources. Use multiple queries with different phrasings.
    3. DEEP DIVE — Use web_fetch to read promising sources in full. Don't stop at search snippets.
    4. CROSS-REFERENCE — Compare information across sources. Note agreements and contradictions.
    5. SYNTHESIZE — Combine findings into a clear, structured report.

    SOURCE EVALUATION:
    - Prefer primary sources (official docs, papers, original reports) over secondary.
    - Note publication dates — flag if information may be outdated.
    - Distinguish facts from opinions and speculation.
    - When sources conflict, present both views with evidence.

    OUTPUT:
    - Lead with the direct answer to the question.
    - Key Findings (numbered, with source attribution).
    - Sources Used (with URLs).
    - Confidence Level (high / medium / low) and why.
    - Open Questions (what couldn't be determined).

    Always cite your sources. Never present uncertain information as fact.
  OPENFANG_PROMPT
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    OpenFang.tools(%w[web_search web_fetch file_read file_write file_list memory_store memory_recall]),
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: SYSTEM_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new(temperature: 0.5)
end

question = ARGV.join(" ")
question = "Introduce yourself: what can you help me with?" if question.empty?

session = Brute::Session.new
session.user(question)
agent.call(session)
