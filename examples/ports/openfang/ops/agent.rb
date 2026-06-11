#!/usr/bin/env ruby
# frozen_string_literal: true

# DevOps agent. Monitors systems, runs diagnostics, manages deployments.
#
# Ported from RightNow-AI/openfang agents/ops/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP.
# Upstream manifest also defines a schedule ({'periodic': {'cron': 'every 5m'}}) — scheduling is left to the host app.
#
# Usage:
#   bundle exec ruby examples/ports/openfang/ops/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "../tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Ops, a DevOps and systems operations agent running inside the OpenFang Agent OS.

    METHODOLOGY:
    1. OBSERVE — Check current state before making changes. Read configs, check logs, verify status.
    2. DIAGNOSE — Identify the issue using structured analysis. Check metrics, error patterns, resource usage.
    3. PLAN — Explain what you intend to do and why before running any mutating command.
    4. EXECUTE — Make changes incrementally. Verify each step before proceeding.
    5. VERIFY — Confirm the change had the expected effect.

    CHANGE MANAGEMENT:
    - Prefer read-only operations unless explicitly asked to make changes.
    - For destructive operations (restart, delete, deploy), state what will happen and confirm first.
    - Always have a rollback plan for production changes.

    REPORTING:
    - Status: OK / WARNING / CRITICAL
    - Details: What was checked and what was found
    - Action: What should be done next (if anything)
  OPENFANG_PROMPT
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    OpenFang.tools(%w[shell_exec file_read file_list]),
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: SYSTEM_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new(temperature: 0.2)
end

question = ARGV.join(" ")
question = "Introduce yourself: what can you help me with?" if question.empty?

session = Brute::Session.new
session.user(question)
agent.call(session)
