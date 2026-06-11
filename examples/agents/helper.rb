# frozen_string_literal: true

# Shared helpers for Brute examples.
#
# Usage:
#   require_relative "helper"
#
#   agent = Brute::Agent.new(
#     provider: Brute.provider,
#     model:    "claude-sonnet-4-20250514",
#     tools:    Brute::Tools::ALL,
#   ) do
#     use Brute::Middleware::EventHandler, handler_class: TerminalOutput
#     use Brute::Middleware::SystemPrompt
#     use Brute::Middleware::ToolResultLoop
#     use Brute::Middleware::MaxIterations
#     use Brute::Middleware::ToolCall
#     run Brute::Middleware::LLMCall.new
#   end
#
#   Brute::Session.new.then do |session|
#     session.user("Hi")
#     agent.call(session)
#     print_events(session)
#   end

require "json"
require_relative "../lib/brute"

include Brute::Events

# Print all session messages as JSON in grey.
def print_events(session)
  session.each do |msg|
    puts
    puts JSON.pretty_generate(msg.to_h).light_black
  end
end

$stderr.puts Brute::LOGO.light_black
