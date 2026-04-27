#!/usr/bin/env ruby
# frozen_string_literal: true

# Parallel sub-agent exploration — a parent agent spawns two read-only
# SubAgents concurrently to explore different aspects of the repo,
# then synthesizes their findings into a single report.
#
# This demonstrates:
# - Brute::SubAgent as a tool inside a parent Brute::Agent
# - The LLM deciding when and how to call sub-agents
# - Parallel sub-agent execution via Async::Barrier in ToolCall middleware
# - SystemPrompt middleware with a custom agent prompt (explore.txt)
# - PrefixedTerminalOutput for sub-agent visibility

require_relative "helper"

# --- Shared explore prompt for both SubAgents ---
#
# Brute::Prompts.agent_prompt("explore") loads text/agents/explore.txt,
# which gives the sub-agent a "file search specialist" persona with
# guidelines for using fs_search, read, and shell (read-only).

EXPLORE_PROMPT = Brute::SystemPrompt.build do |p, _ctx|
  p << Brute::Prompts.agent_prompt("explore")
end

# --- Build two read-only exploration SubAgents ---
#
# Each SubAgent is an Agent that exposes a tool-shaped facade via
# to_ruby_llm. When the parent agent's LLM calls one, ToolCall
# middleware invokes RubyLLM::Tool#call -> execute -> SubAgent#execute,
# which builds a fresh Session and runs the sub-agent's own pipeline.
#
# PrefixedTerminalOutput gives each sub-agent a labeled prefix in the
# terminal so you can see which sub-agent is doing what when they run
# concurrently.

explore_architecture = Brute::SubAgent.new(
  name:        "explore_architecture",
  description: "Delegate an architecture exploration task to a read-only sub-agent. " \
               "This agent specializes in understanding project structure, middleware " \
               "pipelines, class hierarchies, and design patterns. Give it a clear " \
               "description of what architectural aspects to investigate.",
  provider:    Brute.provider,
  model:       "claude-sonnet-4-20250514",
  tools:       [Brute::Tools::FSRead, Brute::Tools::FSSearch],
) do
  use Brute::Middleware::EventHandler,
      handler_class: Brute::Events::PrefixedTerminalOutput,
      prefix: "arch"
  use Brute::Middleware::SystemPrompt, system_prompt: EXPLORE_PROMPT
  use Brute::Middleware::Summarize
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations, max_iterations: 15
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end

explore_tools = Brute::SubAgent.new(
  name:        "explore_tools",
  description: "Delegate a tools exploration task to a read-only sub-agent. " \
               "This agent specializes in understanding tool implementations, " \
               "their parameters, how they are registered, and how the agent " \
               "invokes them. Give it a clear description of what to investigate.",
  provider:    Brute.provider,
  model:       "claude-sonnet-4-20250514",
  tools:       [Brute::Tools::FSRead, Brute::Tools::FSSearch],
) do
  use Brute::Middleware::EventHandler,
      handler_class: Brute::Events::PrefixedTerminalOutput,
      prefix: "tools"
  use Brute::Middleware::SystemPrompt, system_prompt: EXPLORE_PROMPT
  use Brute::Middleware::Summarize
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations, max_iterations: 15
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end

# --- Parent agent with both sub-agents registered as tools ---
#
# to_ruby_llm wraps each SubAgent in an anonymous RubyLLM::Tool subclass
# so LLMCall sends the correct JSON schema to the model, and ToolCall
# can route calls through RubyLLM::Tool#call -> execute -> SubAgent#execute.
#
# Because ToolCall middleware dispatches via Async::Barrier, when the LLM
# emits both tool calls in the same response they execute concurrently.

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    [explore_architecture.to_ruby_llm, explore_tools.to_ruby_llm],
) do
  use Brute::Middleware::EventHandler, handler_class: TerminalOutput
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations, max_iterations: 5
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end

Brute::Session.new(path: File.join(__dir__, "tmp", "session_07.jsonl")).then do |session|
  session.system(<<~PROMPT)
    You are an exploration coordinator. You have two specialist sub-agents
    available as tools:

    1. explore_architecture — investigates project structure, middleware
       pipelines, and class hierarchies.
    2. explore_tools — investigates tool implementations, registration,
       and invocation patterns.

    When the user asks you to explore a codebase:
    - Call BOTH sub-agents in parallel (in the same response), each with
      a focused, detailed task description.
    - Wait for their results.
    - Synthesize their findings into a single, well-organized report.

    Do NOT explore the codebase yourself. Delegate ALL exploration to
    the sub-agents. Your job is coordination and synthesis.
  PROMPT

  session.user(
    "Explore this Ruby project's codebase. I want to understand:\n" \
    "1. The overall architecture — how the middleware pipeline works, " \
    "key classes, execution flow\n" \
    "2. The available tools — what each tool does, how tools are " \
    "registered and invoked\n\n" \
    "Delegate to both sub-agents in parallel and give me a combined report."
  )

  agent.call(session)
  print_events(session)
end
