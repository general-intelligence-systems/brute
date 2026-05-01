# File path: examples/08_a2a_server.rb
#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "helper"
require "brute/a2a/server"
require "brute/a2a/task_store"
require "rack"
require "rackup"

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    Brute::Tools::ALL,
) do
  use Brute::Middleware::EventHandler, handler_class: TerminalOutput
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::Summarize
  use Brute::Middleware::ToolResultLoop
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end

agent_card = {
  name: "brute",
  description: "A coding agent built on ruby_llm",
  url: "http://localhost:9292/a2a",
  version: Brute::VERSION,
  capabilities: { streaming: false, pushNotifications: true },
  defaultInputModes:  ["text/plain"],
  defaultOutputModes: ["text/plain"],
  skills: [
    { id: "code", name: "code", description: "read, write, patch, search code", tags: ["code"] },
  ],
}

Rackup::Server.start(app: Brute::A2A::Server.new(agent: agent, agent_card: agent_card), Port: 9292)
