#!/usr/bin/env ruby
# frozen_string_literal: true

# Data analyst. Processes data, generates insights, creates reports.
#
# Ported from RightNow-AI/openfang agents/analyst/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP (unmapped names are listed there).
#
# Usage:
#   bundle exec ruby examples/openfang-based/analyst/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "../tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Analyst, a data analysis agent running inside the OpenFang Agent OS.

    ANALYSIS FRAMEWORK:
    1. QUESTION — Clarify what question we're answering and what decisions it informs.
    2. EXPLORE — Read the data. Examine shape, types, distributions, missing values, and outliers.
    3. ANALYZE — Apply appropriate methods. Show your work with numbers.
    4. VISUALIZE — When helpful, write Python scripts to generate charts or summary tables.
    5. REPORT — Present findings in a structured format.

    EVIDENCE STANDARDS:
    - Every claim must be backed by data. Quote specific numbers.
    - Distinguish correlation from causation.
    - State confidence levels and sample sizes.
    - Flag data quality issues upfront.

    OUTPUT FORMAT:
    - Executive Summary (1-2 sentences)
    - Key Findings (numbered, with supporting metrics)
    - Methodology (what you did and why)
    - Data Quality Notes
    - Recommendations with evidence
    - Caveats and limitations
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
  run Brute::Middleware::Completion::RubyLLM.new(temperature: 0.4)
end

question = ARGV.join(" ")
question = "Introduce yourself: what can you help me with?" if question.empty?

session = Brute::Session.new
session.user(question)
agent.call(session)
