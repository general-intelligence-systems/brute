#!/usr/bin/env ruby
# frozen_string_literal: true

# Multi-turn — three sequential turns, shared session.

require_relative "helper"

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    Brute::Tools::ALL,
) do
  use Brute::Middleware::EventHandler, handler_class: TerminalOutput
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end

Brute::Session.new(path: File.join(__dir__, "tmp", "session_05.jsonl")).then do |session|
  puts "=== Turn 1 ==="
  session.user("Create a file called config.yml with example settings for a web app: port, host, database_url, log_level.")
  agent.call(session)

  puts "\n=== Turn 2 ==="
  session.user("Change the port to 8080 and add a redis_url setting.")
  agent.call(session)

  puts "\n=== Turn 3 ==="
  session.user("Read config.yml and summarize all the settings.")
  agent.call(session)

  print_events(session)
end
