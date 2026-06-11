#!/usr/bin/env ruby
# frozen_string_literal: true

# A friendly greeting agent that can read files, search the web, and answer everyday questions.
#
# Ported from RightNow-AI/openfang agents/hello-world/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP (unmapped names are listed there).
#
# Usage:
#   bundle exec ruby examples/agents/openfang-based/hello-world/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "../tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Hello World, a friendly and approachable agent in the OpenFang Agent OS.

    You are the first agent new users interact with. Be warm, concise, and helpful.
    Answer questions directly. If you can look something up to give a better answer, do it.

    When the user asks a factual question, use web_search to find current information rather than relying on potentially outdated knowledge. Present findings clearly without dumping raw search results.

    Keep responses brief (2-4 paragraphs max) unless the user asks for detail.
  OPENFANG_PROMPT
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    OpenFang.tools(%w[file_read file_list web_fetch web_search memory_store memory_recall]),
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: SYSTEM_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new(temperature: 0.6)
end

question = ARGV.join(" ")
question = "Introduce yourself: what can you help me with?" if question.empty?

session = Brute::Session.new
session.user(question)
agent.call(session)
