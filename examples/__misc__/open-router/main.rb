#!/usr/bin/env ruby
# frozen_string_literal: true

# Brute + open_router_enhanced (https://github.com/estiens/open_router_enhanced)
# — the minimal OpenRouter agent.
#
# The terminal app is Brute::Middleware::OpenRouter::Completion: one chat
# completion per pass, tools advertised (not executed); Brute's ToolPipeline +
# Loop::ToolResult middleware run the tools and loop. Model defaults to the
# open_router_enhanced default; override with BRUTE_MODEL.
#
#   OPENROUTER_API_KEY=... nix run ./examples/open-router -- "your task"

require "open_router"
require "brute"

OpenRouter.configure do |config|
  config.access_token = ENV.fetch("OPENROUTER_API_KEY") do
    warn "Set OPENROUTER_API_KEY to run this example."
    exit 1
  end
end

options = {}
options[:model] = ENV["BRUTE_MODEL"] if ENV["BRUTE_MODEL"]

agent = Brute.agent
  .use(Brute::Middleware::SystemPrompt)
  .use(Brute::Middleware::Loop::ToolResult)
  .use(Brute::Middleware::MaxIterations)
  .use(Brute::Middleware::ToolPipeline, tools: Brute::Tools::ALL)
  .run(Brute::Middleware::OpenRouter::Completion.new({}, **options))

task = ARGV.empty? ? "What files are in the current directory? List them." : ARGV.join(" ")
puts agent.start(task)
