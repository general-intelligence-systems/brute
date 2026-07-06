#!/usr/bin/env ruby
# frozen_string_literal: true

# Brute + the official openai gem (https://github.com/openai/openai-ruby) —
# Brute manages the turn.
#
# Brute is framework-agnostic: it depends on no LLM library. The terminal
# `run` proc owns the LLM call and ALL LLM configuration (model,
# credentials); Brute::MessageTransport::OpenAI translates at the boundary:
#
#   outbound  Brute::Message log       -> chat.completions message hashes (.dump_all)
#   inbound   OpenAI chat completion   -> Brute::Message                  (.wrap_each)
#
# Tool-call arguments arrive from OpenAI as JSON strings; the transport
# parses them into Hashes on the way in and re-encodes them on the way out.
# The proc does ONE completion per pass (tools advertised, not executed);
# Brute's ToolPipeline + Loop::ToolResult middleware run the tools and loop.
#
#   OPENAI_API_KEY=... BRUTE_MODEL=gpt-5 ruby examples/openai.rb

require_relative "agents/helper"
require "openai"

MODEL = ENV.fetch("BRUTE_MODEL", "gpt-5")

# Advertise Brute's tools as chat-completions function definitions.
def openai_tools(tools)
  Brute.tools(tools).values.map do |adapter|
    defn = adapter.to_h
    { type: "function", function: { name: defn[:name], description: defn[:description], parameters: defn[:parameters] } }
  end
end

agent = Brute.agent
  .use(Brute::Middleware::EventHandler, handler_class: TerminalOutput)
  .use(Brute::Middleware::SessionLog, path: File.join(__dir__, "agents", "tmp", "session_openai.jsonl"))
  .use(Brute::Middleware::SystemPrompt)
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::MaxIterations)
  .use(Brute::Middleware::ToolPipeline, tools: Brute::Tools::ALL)
  .run do |env|
    client = OpenAI::Client.new(api_key: ENV.fetch("OPENAI_API_KEY"))

    params = {
      model:    MODEL,
      messages: Brute::MessageTransport::OpenAI.dump_all(env[:messages]),
    }
    tools = openai_tools(env[:tools])   # advertised by ToolPipeline
    params[:tools] = tools unless tools.empty?

    response = client.chat.completions.create(**params)

    Brute::MessageTransport::OpenAI.wrap_each(response) do |message|
      env[:messages] << message
    end
  end

# SessionLog (in the stack) loads/persists the conversation; just pass the turn.
env = agent.start("What files are in the current directory? List them.")
print_events(env[:messages])
