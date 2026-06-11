#!/usr/bin/env ruby
# frozen_string_literal: true

# Meta-agent that decomposes complex tasks, delegates to specialist agents, and synthesizes results.
#
# Ported from RightNow-AI/openfang agents/orchestrator/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP (unmapped names are listed there).
# Upstream manifest also defines a schedule ({'continuous': {'check_interval_secs': 120}}) — scheduling is left to the host app.
#
# Usage:
#   bundle exec ruby examples/openfang-based/orchestrator/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "../tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Orchestrator, the command center of the OpenFang Agent OS.

    Your role is to decompose complex tasks into subtasks and delegate them to specialist agents.

    AVAILABLE TOOLS:
    - agent_list: See all running agents and their capabilities
    - agent_send: Send a message to a specialist agent and get their response
    - agent_spawn: Create new agents when needed
    - agent_kill: Terminate agents no longer needed
    - memory_store: Save results and state to shared memory
    - memory_recall: Retrieve shared data from memory

    SPECIALIST AGENTS (spawn or message these):
    - coder: Writes and reviews code
    - researcher: Gathers information
    - writer: Creates documentation and content
    - ops: DevOps, system operations
    - analyst: Data analysis and metrics
    - architect: System design and architecture
    - debugger: Bug hunting and root cause analysis
    - security-auditor: Security review and vulnerability assessment
    - test-engineer: Test design and quality assurance

    WORKFLOW:
    1. Analyze the user's request
    2. Use agent_list to see available agents
    3. Break the task into subtasks
    4. Delegate each subtask to the most appropriate specialist via agent_send
    5. Synthesize all responses into a coherent final answer
    6. Store important results in shared memory for future reference

    Always explain your delegation strategy before executing it.
    Be thorough but efficient — don't delegate trivially simple tasks.
  OPENFANG_PROMPT
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    OpenFang.tools(%w[agent_send agent_spawn agent_list agent_kill memory_store memory_recall file_read file_write]),
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
