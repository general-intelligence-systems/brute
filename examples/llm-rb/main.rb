#!/usr/bin/env ruby
# frozen_string_literal: true

# Brute + llm.rb (https://github.com/llmrb/llm.rb) — Brute manages the turn.
#
# Brute is framework-agnostic: it depends on no LLM library. The terminal
# `run` proc owns the LLM call and ALL LLM configuration (provider, model,
# credentials); Brute::MessageTransport::LLM translates at the boundary:
#
#   outbound  Brute::Message log  -> LLM::Message array   (.dump_all)
#   inbound   LLM::Response       -> Brute::Message       (.wrap_each)
#
# llm.rb accepts tools as plain provider-format hashes, so Brute's neutral
# adapter definitions (#to_h) map straight in. The proc does ONE completion
# per pass (tools advertised, not executed); Brute's ToolPipeline +
# Loop::ToolResult middleware run the tools and loop.
#
# Defaults to a local Ollama (see docker-compose.yml). Override with env vars:
#   BRUTE_PROVIDER=openai BRUTE_MODEL=gpt-5 OPENAI_API_KEY=... nix run ./examples/llm-rb

require_relative "helper"
require "llm"

PROVIDER = ENV.fetch("BRUTE_PROVIDER", "ollama").to_sym
MODEL    = ENV.fetch("BRUTE_MODEL", "llama3.2")

def llm_provider
  case PROVIDER
  when :openai    then LLM.openai(key: ENV.fetch("OPENAI_API_KEY"))
  when :anthropic then LLM.anthropic(key: ENV.fetch("ANTHROPIC_API_KEY"))
  else                 LLM.ollama(key: nil)
  end
end

# Advertise Brute's tools to llm.rb as chat-completions function hashes.
def llm_tools(tools)
  Brute.tools(tools).values.map do |adapter|
    defn = adapter.to_h
    { type: "function", function: { name: defn[:name], description: defn[:description], parameters: defn[:parameters] } }
  end
end

agent = Brute.agent
  .use(Brute::Middleware::EventHandler, handler_class: TerminalOutput)
  .use(Brute::Middleware::SessionLog, path: File.join(Dir.pwd, "tmp", "session_llm.jsonl"))
  .use(Brute::Middleware::SystemPrompt)
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::MaxIterations)
  .use(Brute::Middleware::ToolPipeline, tools: Brute::Tools::ALL)
  .run do |env|
    llm = llm_provider

    # llm.rb's #complete takes the newest message as the prompt and the
    # rest of the conversation via :messages.
    *history, last = Brute::MessageTransport::LLM.dump_all(env[:messages])

    response = llm.complete(
      last.content,
      role:     last.role,
      messages: history,
      model:    MODEL,
      tools:    llm_tools(env[:tools]),   # advertised by ToolPipeline
    )

    Brute::MessageTransport::LLM.wrap_each(response) do |message|
      env[:messages] << message
    end
  end

# SessionLog (in the stack) loads/persists the conversation; just pass the turn.
env = agent.start("What files are in the current directory? List them.")
print_events(env[:messages])
