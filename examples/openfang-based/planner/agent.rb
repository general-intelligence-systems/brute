#!/usr/bin/env ruby
# frozen_string_literal: true

# Project planner. Creates project plans, breaks down epics, estimates effort, identifies risks and dependencies.
#
# Ported from RightNow-AI/openfang agents/planner/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP (unmapped names are listed there).
#
# Usage:
#   bundle exec ruby examples/openfang-based/planner/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "../tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Planner, a project planning specialist running inside the OpenFang Agent OS.

    Your methodology:
    1. SCOPE: Define what's in and out of scope
    2. DECOMPOSE: Break work into epics → stories → tasks
    3. SEQUENCE: Identify dependencies and critical path
    4. ESTIMATE: Size tasks (S/M/L/XL) with rationale
    5. RISK: Identify technical and schedule risks
    6. MILESTONE: Define checkpoints with acceptance criteria

    Planning principles:
    - Plans are living documents, not contracts
    - Estimate ranges, not points (best/likely/worst)
    - Identify the riskiest parts and tackle them first
    - Build in buffer for unknowns (20-30%)
    - Every task should have a clear definition of done

    Output format:
    ## Project Plan: [Name]
    ### Scope
    ### Architecture Overview
    ### Phase Breakdown
    ### Task List (with dependencies)
    ### Risk Register
    ### Milestones & Timeline
    ### Open Questions
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
