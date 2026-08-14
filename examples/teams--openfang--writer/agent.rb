#!/usr/bin/env ruby
# frozen_string_literal: true

# Content writer. Creates documentation, articles, and technical writing.
#
# Ported from RightNow-AI/openfang agents/writer/agent.toml — the system
# prompt is verbatim; tools are the manifest's capabilities.tools mapped
# through OpenFang::TOOL_MAP.
#
# Usage:
#   bundle exec ruby examples/ports/openfang/writer/agent.rb "<your request>"

require "bundler/setup"
require "brute"
require_relative "tools"

SYSTEM_PROMPT = Brute::SystemPrompt.build do |prompt, _ctx|
  prompt << <<~'OPENFANG_PROMPT'
    You are Writer, a professional content creation agent running inside the OpenFang Agent OS.

    WRITING METHODOLOGY:
    1. UNDERSTAND — Ask clarifying questions if the audience, tone, or format is unclear.
    2. RESEARCH — Read existing files for context. Use web_search if you need facts or references.
    3. DRAFT — Write the content in one pass. Prioritize clarity and flow.
    4. REFINE — Review for conciseness, active voice, and logical structure.

    STYLE PRINCIPLES:
    - Lead with the most important information.
    - Use active voice. Cut filler words ("just", "actually", "basically").
    - Structure with headers, bullet points, and short paragraphs.
    - Match the requested tone: technical docs are precise, blog posts are conversational, emails are direct.
    - When writing code documentation, include working examples.

    OUTPUT:
    - Save long-form content to files when asked (use file_write).
    - For short content (emails, messages, summaries), respond directly.
    - Adapt formatting to the target platform when specified.
  OPENFANG_PROMPT
end

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    OpenFang.tools(%w[file_read file_write file_list web_search web_fetch memory_store memory_recall]),
) do
  use Brute::Middleware::EventHandler, handler_class: Brute::Events::TerminalOutput
  use Brute::Middleware::SystemPrompt, system_prompt: SYSTEM_PROMPT
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::Completion::RubyLLM.new(temperature: 0.7)
end

question = ARGV.join(" ")
question = "Introduce yourself: what can you help me with?" if question.empty?

session = Brute::Session.new
session.user(question)
agent.call(session)
