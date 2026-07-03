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
#       ctx = RubyLLM.context { |c| c.ollama_api_base = ENV["OLLAMA_API_BASE"] }
#       model, provider = RubyLLM::Models.resolve(
#         "llama3.2", provider: :ollama, assume_exists: true, config: ctx.config)
#       response = provider.complete(env[:messages],
#                                    tools:       Brute.rubyllm_tools(env[:tools]),
#                                    temperature: 0.7,
#                                    model:       model)
#       RubyLLM::MessageTransport.new(response).wrap_each { |m| env[:messages] << m }
#     end
#
#   env = agent.start("What files are here?")
#   print_events(env[:messages])

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
