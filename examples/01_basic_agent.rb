#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "helper"

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    Brute::Tools::ALL,
) do
  use Brute::Middleware::EventHandler, handler_class: TerminalOutput
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::ToolResults
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end

Brute::Session.new.then do |session|
  session.user("What files are in the current directory? List them.")
  agent.call(session)
  print_events(session)
end
