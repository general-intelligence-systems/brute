#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic agent — Brute manages the turn.
#
# Brute.agent returns an AgentPipeline that is its own builder: chain .use and
# .run (both return it) to configure, then .start to run it. No config. Tools
# go to the ToolPipeline middleware (advertises them on env[:tools] going in,
# runs them coming out); the conversation log is loaded/persisted by SessionLog.
# The terminal .run proc makes the LLM call and owns ALL LLM configuration
# (provider, model, credentials).
#
# Brute is framework-agnostic — env[:messages] is a plain Array of
# Brute::Message and the run proc is written with whatever LLM library you
# prefer. This example uses ruby_llm; a MessageTransport translates at the
# boundary (Brute -> library with .dump_all, library -> Brute with
# .wrap_each). See also examples/llm.rb, examples/openai.rb and
# examples/anthropic.rb for the same agent on other libraries.
#
# You invoke the returned Agent with `agent.start(prompt)`.
#
# Here the proc does ONE completion (tools advertised, not executed), and
# Brute's ToolPipeline + Loop::ToolResult middleware run the tools and loop —
# Brute is the turn manager.
#
# Defaults to a local Ollama (see docker-compose.yml). Override with env vars:
#   BRUTE_PROVIDER=anthropic BRUTE_MODEL=claude-opus-4-8 ANTHROPIC_API_KEY=... ruby examples/agents/01_basic_agent.rb

require_relative "helper"
require "ruby_llm"

PROVIDER = ENV.fetch("BRUTE_PROVIDER", "ollama").to_sym
MODEL    = ENV.fetch("BRUTE_MODEL", "llama3.2")

# Advertise Brute's tools to ruby_llm: each neutral adapter (name,
# description, JSON schema via #to_h) becomes a RubyLLM::Tool.
def rubyllm_tools(tools)
  Brute.tools(tools).transform_values do |adapter|
    schema = adapter.to_h[:parameters]
    Class.new(RubyLLM::Tool) do
      description adapter.description
      params schema
      define_method(:name) { adapter.name }
      define_method(:execute) { |**args| adapter.call(args) }
    end.new
  end
end

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
      Brute::MessageTransport::RubyLLM.dump_all(env[:messages]),
      tools:       rubyllm_tools(env[:tools]),   # advertised by ToolPipeline
      temperature: 0.7,
      model:       model,
    )

    Brute::MessageTransport::RubyLLM.wrap_each(response) do |message|
      env[:messages] << message
    end
  end

# SessionLog (in the stack) loads/persists the conversation; just pass the turn.
env = agent.start("What files are in the current directory? List them.")
print_events(env[:messages])
