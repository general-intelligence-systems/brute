#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic agent — Brute manages the turn.
#
# Brute.agent returns an AgentPipeline that is its own builder: chain .use and
# .run (both return it) to configure, then .start to run it. No config. Tools
# go to the ToolPipeline middleware (advertises them on env[:tools] going in,
# runs them coming out); the conversation log is loaded/persisted by SessionLog.
# The terminal .run proc makes the LLM call and owns ALL LLM configuration
# (provider, model, credentials) via RubyLLM.context.
#
# You invoke the returned Agent with `agent.start(prompt)`.
#
# Here the proc does ONE completion (tools advertised, not executed), and
# Brute's ToolPipeline + Loop::ToolResult middleware run the tools and loop —
# Brute is the turn manager. MessageTransport wraps the RubyLLM result and
# yields it back into the log in Brute's format.
#
# Defaults to a local Ollama (see docker-compose.yml). Override with env vars:
#   BRUTE_PROVIDER=anthropic BRUTE_MODEL=claude-sonnet-4-20250514 ANTHROPIC_API_KEY=... ruby examples/agents/01_basic_agent.rb

require_relative "helper"

PROVIDER = ENV.fetch("BRUTE_PROVIDER", "ollama").to_sym
MODEL    = ENV.fetch("BRUTE_MODEL", "llama3.2")

agent = Brute.agent
  .use(Brute::Middleware::EventHandler, handler_class: TerminalOutput)
  .use(Brute::Middleware::SessionLog, path: File.join(__dir__, "tmp", "session_01.jsonl"))
  .use(Brute::Middleware::SystemPrompt)
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::MaxIterations)
  .use(Brute::Middleware::ToolPipeline, tools: Brute::Tools::ALL)
  .run do |env|
    # All LLM config lives here, in the call proc.
    context = RubyLLM.context do |config|
      config.ollama_api_base   = ENV.fetch("OLLAMA_API_BASE", "http://localhost:11434/v1")
      config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
      config.openai_api_key    = ENV["OPENAI_API_KEY"]
    end

    model, provider = RubyLLM::Models.resolve(
      MODEL, provider: PROVIDER, assume_exists: true, config: context.config
    )

    response = provider.complete(
      env[:messages],
      tools:       Brute.rubyllm_tools(env[:tools]),   # advertised by ToolPipeline
      temperature: 0.7,
      model:       model,
    )

    RubyLLM::MessageTransport.new(response).wrap_each do |message|
      env[:messages] << message
    end
  end

# SessionLog (in the stack) loads/persists the conversation; just pass the turn.
env = agent.start("What files are in the current directory? List them.")
print_events(env[:messages])
