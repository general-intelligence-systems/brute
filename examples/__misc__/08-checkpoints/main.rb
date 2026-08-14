#!/usr/bin/env ruby
# frozen_string_literal: true

# Checkpoints — durable execution for the tool loop.
#
# SessionLog persists the conversation once, at the end of the turn. The
# Checkpoint middleware sits just *inside* Loop::ToolResult and snapshots the
# conversation after every pass — one checkpoint per LLM call + tool batch —
# to an append-only JSONL chain where each record points at its parent. That
# chain buys three things:
#
#   resume       BRUTE_CHECKPOINT=latest  — pick up where the last snapshot
#                left off; a crash mid-turn costs one iteration, not the turn
#   time travel  BRUTE_CHECKPOINT=<id>    — restart from any snapshot
#   forking      checkpoints written after a time-travel resume carry the
#                resumed id as parent_id, branching the chain in place
#
# Run it three ways:
#
#   nix run ./examples/08-checkpoints                        # fresh turn
#   BRUTE_CHECKPOINT=latest nix run ./examples/08-checkpoints
#   BRUTE_CHECKPOINT=<id from the printed chain> nix run ./examples/08-checkpoints
#
# Defaults to a local Ollama (see docker-compose.yml). Override with env vars:
#   BRUTE_PROVIDER=anthropic BRUTE_MODEL=claude-opus-4-8 ANTHROPIC_API_KEY=... nix run ./examples/08-checkpoints

require_relative "helper"
require "ruby_llm"

PROVIDER        = ENV.fetch("BRUTE_PROVIDER", "ollama").to_sym
MODEL           = ENV.fetch("BRUTE_MODEL", "llama3.2")
CHECKPOINT_PATH = File.join(Dir.pwd, "tmp", "checkpoints_08.jsonl")

resume = case ENV["BRUTE_CHECKPOINT"]
         when nil, ""  then nil
         when "latest" then :latest
         else               ENV["BRUTE_CHECKPOINT"]
         end

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
  .use(Brute::Middleware::SystemPrompt)
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::Checkpoint, path: CHECKPOINT_PATH, resume: resume)
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
      tools:       rubyllm_tools(env[:tools]),
      temperature: 0.7,
      model:       model,
    )

    Brute::MessageTransport::RubyLLM.wrap_each(response) do |message|
      env[:messages] << message
    end
  end

prompt =
  if resume
    puts "=== Resuming from #{resume == :latest ? "the latest checkpoint" : "checkpoint #{resume}"} ==="
    "Based on what you have explored so far, summarize this project in one paragraph."
  else
    puts "=== Fresh turn (checkpointing every iteration to #{CHECKPOINT_PATH}) ==="
    "Explore this project: list the files here, then read the readme."
  end

agent.start(prompt)

puts "\nCheckpoint chain:"
Brute::Middleware::Checkpoint.list(CHECKPOINT_PATH).each do |r|
  puts format("  %s  <- %-12s  iteration=%d  messages=%d",
              r[:id], r[:parent_id] || "(root)", r[:iteration], r[:messages].size).light_black
end
puts "\nResume the latest:  BRUTE_CHECKPOINT=latest ruby #{$PROGRAM_NAME}"
puts "Fork from a snapshot: BRUTE_CHECKPOINT=<id> ruby #{$PROGRAM_NAME}"
