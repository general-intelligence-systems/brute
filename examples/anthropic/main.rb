#!/usr/bin/env ruby
# frozen_string_literal: true

# Brute + the official anthropic gem
# (https://github.com/anthropics/anthropic-sdk-ruby) — Brute manages the turn.
#
# Brute is framework-agnostic: it depends on no LLM library. The terminal
# `run` proc owns the LLM call and ALL LLM configuration (model,
# credentials); Brute::MessageTransport::Anthropic translates at the
# boundary:
#
#   outbound  Brute::Message log   -> Messages API params (.system_text / .dump_all)
#   inbound   Anthropic::Message   -> Brute::Message      (.wrap_each)
#
# Anthropic's Messages API is content-block shaped: the system prompt is a
# top-level parameter, tool calls are tool_use blocks, and tool results are
# tool_result blocks inside a user turn — the transport absorbs all of that.
# The proc does ONE completion per pass (tools advertised, not executed);
# Brute's ToolPipeline + Loop::ToolResult middleware run the tools and loop.
#
#   ANTHROPIC_API_KEY=... BRUTE_MODEL=claude-opus-4-8 nix run ./examples/anthropic

require_relative "helper"
require "anthropic"

MODEL = ENV.fetch("BRUTE_MODEL", "claude-opus-4-8")

# Advertise Brute's tools as Anthropic tool definitions.
def anthropic_tools(tools)
  Brute.tools(tools).values.map do |adapter|
    defn = adapter.to_h
    { name: defn[:name], description: defn[:description], input_schema: defn[:parameters] }
  end
end

agent = Brute.agent
  .use(Brute::Middleware::EventHandler, handler_class: TerminalOutput)
  .use(Brute::Middleware::SessionLog, path: File.join(Dir.pwd, "tmp", "session_anthropic.jsonl"))
  .use(Brute::Middleware::SystemPrompt)
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::MaxIterations)
  .use(Brute::Middleware::ToolPipeline, tools: Brute::Tools::ALL)
  .run do |env|
    client = Anthropic::Client.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    transport = Brute::MessageTransport::Anthropic

    params = {
      model:      MODEL,
      max_tokens: 16_000,
      messages:   transport.dump_all(env[:messages]),
    }
    system_text = transport.system_text(env[:messages])
    params[:system_] = system_text unless system_text.empty?

    tools = anthropic_tools(env[:tools])   # advertised by ToolPipeline
    params[:tools] = tools unless tools.empty?

    response = client.messages.create(**params)

    transport.wrap_each(response) do |message|
      env[:messages] << message
    end
  end

# SessionLog (in the stack) loads/persists the conversation; just pass the turn.
env = agent.start("What files are in the current directory? List them.")
print_events(env[:messages])
