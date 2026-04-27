#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only agent — restricted tool set, no write/patch/shell access.

require_relative "helper"

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    [Brute::Tools::FSRead, Brute::Tools::FSSearch],
) do
  use Brute::Middleware::EventHandler, handler_class: TerminalOutput
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end

Brute::Session.new(path: File.join(__dir__, "tmp", "session_06.jsonl")).then do |session|
  session.user(
    "You are a read-only code analysis agent. You can read files and search but cannot modify anything.\n\n" \
    "Search the lib/ directory for any TODO or FIXME comments and summarize what you find."
  )
  agent.call(session)
  print_events(session)
end
