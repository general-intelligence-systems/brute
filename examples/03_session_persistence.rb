#!/usr/bin/env ruby
# frozen_string_literal: true

# Session persistence — messages are saved to a JSONL file on every append.
# Run this twice to see the session resume from where it left off.

require_relative "helper"

SESSION_PATH = File.join(__dir__, "tmp", "session_03.jsonl")

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    [],
) do
  use Brute::Middleware::EventHandler, handler_class: TerminalOutput
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::ToolResults
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end

# Load existing session (or start fresh). Every << auto-persists to disk.
session = Brute::Session.from_jsonl(SESSION_PATH)

if session.empty?
  # First run — tell it something
  puts "=== Turn 1 (first run) ==="
  session.user("Remember this: the secret project codename is FALCON. Just acknowledge.")
  agent.call(session)
else
  # Subsequent run — ask it back
  puts "=== Turn 2 (resumed from #{SESSION_PATH}) ==="
  session.user("What is the secret project codename I told you?")
  agent.call(session)
end

print_events(session)
