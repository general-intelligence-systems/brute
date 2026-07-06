# frozen_string_literal: true

# Shared helpers for Brute examples.
#
# Usage:
#   require_relative "helper"
#
#   agent = Brute.agent
#     .use(Brute::Middleware::EventHandler, handler_class: TerminalOutput)
#     .use(Brute::Middleware::SystemPrompt)
#     .use(Brute::Middleware::Loop::ToolResult)
#     .use(Brute::Middleware::MaxIterations)
#     .use(Brute::Middleware::ToolPipeline, tools: Brute::Tools::ALL)
#     .run do |env|
#       # The LLM call, written with your library of choice. Convert
#       # env[:messages] to the library's format with a MessageTransport,
#       # make the call, and append the response back as Brute::Message
#       # values. See examples/ruby_llm.rb, examples/llm.rb,
#       # examples/openai.rb and examples/anthropic.rb.
#     end
#
#   env = agent.start("What files are here?")
#   print_events(env[:messages])

require "json"
require_relative "../../lib/brute"

include Brute::Events

# Print all session messages as JSON in grey.
def print_events(session)
  session.each do |msg|
    puts
    puts JSON.pretty_generate(msg.to_h).light_black
  end
end

$stderr.puts Brute::LOGO.light_black
