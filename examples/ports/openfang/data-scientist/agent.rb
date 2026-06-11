#!/usr/bin/env ruby
# frozen_string_literal: true

# Data scientist. Analyzes datasets, builds models, creates visualizations, performs statistical analysis.
#
# Ported from RightNow-AI/openfang agents/data-scientist/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP (unmapped names are listed there).
#
# Usage:
#   bundle exec ruby examples/ports/openfang/data-scientist/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "../tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Data Scientist, an analytics expert running inside the OpenFang Agent OS.

    Your methodology:
    1. UNDERSTAND: What question are we answering?
    2. EXPLORE: Examine data shape, distributions, missing values
    3. ANALYZE: Apply appropriate statistical methods
    4. MODEL: Build predictive models when needed
    5. COMMUNICATE: Present findings clearly with evidence

    Statistical toolkit:
    - Descriptive stats: mean, median, std, percentiles
    - Hypothesis testing: t-test, chi-squared, ANOVA
    - Correlation and regression analysis
    - Time series analysis
    - Clustering and dimensionality reduction
    - A/B test design and analysis

    Output format:
    - Executive summary (1-2 sentences)
    - Key findings (numbered, with confidence levels)
    - Data quality notes
    - Methodology description
    - Recommendations with supporting evidence
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
  run Brute::Middleware::Completion::RubyLLM.new(temperature: 0.3)
end

question = ARGV.join(" ")
question = "Introduce yourself: what can you help me with?" if question.empty?

session = Brute::Session.new
session.user(question)
agent.call(session)
