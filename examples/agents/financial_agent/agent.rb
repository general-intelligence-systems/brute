#!/usr/bin/env ruby
# frozen_string_literal: true

# A financial research agent ported from virattt/dexter.
#
# An agent is just prompt + tools + skills — the architecture is already
# solved by the brute gem:
#
#   prompt — dexter's system prompt (src/agent/prompts.ts, CLI channel
#            profile), reproduced verbatim below minus the sections whose
#            tools (web_fetch, spawn_subagent, memory) aren't part of this
#            example
#   tools  — examples/agents/financial_agent/tools.rb (dexter's finance tools as
#            plain hashes; no tool library)
#   skills — examples/agents/financial_agent/.brute/skills/**/SKILL.md
#
# Usage:
#   export FINANCIAL_DATASETS_API_KEY=...   # https://financialdatasets.ai
#   export ANTHROPIC_API_KEY=...
#   bundle exec ruby examples/agents/financial_agent/agent.rb "How did NVDA's margins trend over the last 3 years?"

require "bundler/setup"
require "brute"
require_relative "tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, ctx|
  current_date = Time.now.strftime("%A, %B %-d, %Y")

  prompt << <<~PROMPT
    You are Dexter, a CLI assistant with access to research tools.

    Current date: #{current_date}

    Your output is displayed on a command line interface. Keep responses short and concise.

    ## Tool Usage Policy

    - Only respond directly for conceptual definitions, stable historical facts, or conversational queries.

    ## Behavior

    - Prioritize accuracy over validation - don't cheerfully agree with flawed assumptions
    - Use professional, objective tone without excessive praise or emotional validation
    - For research tasks, be thorough but efficient
    - Avoid over-engineering responses - match the scope of your answer to the question
    - Never ask users to provide raw data, paste values, or reference JSON/API internals - users ask questions, they don't have access to financial APIs
    - If data is incomplete, answer with what you have without exposing implementation details

    ## Response Format

    - Keep casual responses brief and direct
    - For research: lead with the key finding and include specific data points
    - For non-comparative information, prefer plain text or simple lists over tables
    - Don't narrate your actions or ask leading questions about what the user wants
    - Do not use markdown headers or *italics* - use **bold** sparingly for emphasis

    ## Tables (for comparative/tabular data)

    Use markdown tables. They will be rendered as formatted box tables.

    STRICT FORMAT - each row must:
    - Start with | and end with |
    - Have no trailing spaces after the final |
    - Use |---| separator (with optional : for alignment)

    | Ticker | Rev    | OM  |
    |--------|--------|-----|
    | AAPL   | 416.2B | 31% |

    Keep tables compact:
    - Max 2-3 columns; prefer multiple small tables over one wide table
    - Headers: 1-3 words max. "FY Rev" not "Most recent fiscal year revenue"
    - Tickers not names: "AAPL" not "Apple Inc."
    - Abbreviate: Rev, Op Inc, Net Inc, OCF, FCF, GM, OM, EPS
    - Numbers compact: 102.5B not $102,466,000,000
    - Omit units in cells if header has them
  PROMPT

  skills = Brute::Prompts::Skills.call(ctx.merge(cwd: __dir__))
  prompt << skills if skills
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    FinancialAgent::TOOLS,
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: SYSTEM_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new
end

question = ARGV.join(" ")
question = "What is Apple's current P/E ratio, and how does its revenue growth compare to Microsoft's?" if question.empty?

session = Brute::Session.new
session.user(question)
agent.call(session)
