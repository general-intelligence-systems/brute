#!/usr/bin/env ruby
# frozen_string_literal: true

# Custom rules — constrain agent behavior via system prompt.

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

Brute::Session.new(path: File.join(__dir__, "tmp", "session_04.jsonl")).then do |session|
  session.user(
    "Follow these project rules:\n\n" \
    "- All Ruby code MUST use frozen_string_literal comments.\n" \
    "- Always use `snake_case` for method names.\n" \
    "- Every class MUST have a one-line comment describing its purpose.\n" \
    "- Use `raise ArgumentError` for invalid inputs, never `puts` an error.\n\n" \
    "Create a file called user.rb with a User class that has a name attribute " \
    "and a #greet method that returns a greeting string. Follow the project rules."
  )
  agent.call(session)
  print_events(session)
end
