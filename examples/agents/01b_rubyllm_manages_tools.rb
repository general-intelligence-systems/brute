#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic agent — RubyLLM manages the tools.
#
# Same Brute.agent builder (no config), but there is no ToolPipeline middleware:
# the terminal `run` block hands the tools straight to RubyLLM.chat and lets it
# own the whole agentic loop (chat.complete calls the model, runs any tool calls
# internally, repeats until it stops). So here the tools are named in the proc,
# not passed to a middleware. LLM config also lives in the proc, via
# RubyLLM.context.
#
# MessageTransport still wraps the result — it takes every message the chat
# produced and yields them into the log in Brute's format.
#
# Defaults to a local Ollama (see docker-compose.yml). Override with env vars:
#   BRUTE_PROVIDER=anthropic BRUTE_MODEL=claude-sonnet-4-20250514 ANTHROPIC_API_KEY=... ruby examples/agents/01b_rubyllm_manages_tools.rb

require_relative "helper"

PROVIDER = ENV.fetch("BRUTE_PROVIDER", "ollama").to_sym
MODEL    = ENV.fetch("BRUTE_MODEL", "llama3.2")

agent = Brute.agent
  .use(Brute::Middleware::EventHandler, handler_class: TerminalOutput)
  .use(Brute::Middleware::SystemPrompt)
  .run do |env|
    # All LLM config lives here, in the call proc.
    chat = RubyLLM.context do |config|
      config.ollama_api_base   = ENV.fetch("OLLAMA_API_BASE", "http://localhost:11434/v1")
      config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
      config.openai_api_key    = ENV["OPENAI_API_KEY"]
    end.chat(model: MODEL, provider: PROVIDER, assume_model_exists: true)

    env[:messages].each { |message| chat.add_message(message) }
    chat.with_tools(*Brute.rubyllm_tools(Brute::Tools::ALL).values)  # tools named here

    before = chat.messages.length
    chat.complete   # RubyLLM runs the tool loop internally

    RubyLLM::MessageTransport.new(chat.messages[before..]).wrap_each do |message|
      env[:messages] << message
    end
  end

env = agent.start("What files are in the current directory? List them.")
print_events(env[:messages])
