#!/usr/bin/env ruby
# frozen_string_literal: true

# Session persistence — two turns share the same session.

require_relative "helper"

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

Brute::Session.new.then do |session|
  # First turn — tell it something
  puts "=== Turn 1 ==="
  session.user("Remember this: the secret project codename is FALCON. Just acknowledge.")
  agent.call(session)

  # Second turn — same session, ask it back
  puts "\n=== Turn 2 ==="
  session.user("What is the secret project codename I told you?")
  agent.call(session)

  print_events(session)
end
