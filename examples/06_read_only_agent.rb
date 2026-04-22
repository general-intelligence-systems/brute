#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only agent — restricted tool set, no write/patch/shell access.
#
# Uses a local Ollama instance. Start Ollama first:
#   ollama serve
#   ollama pull qwen2.5:14b

require_relative "../lib/brute"
require "json"

readonly_tools = [
  Brute::Tools::FSRead,
  Brute::Tools::FSSearch,
  Brute::Tools::TodoRead,
  Brute::Tools::TodoWrite,
]

agent = Brute.agent(provider: Brute::Providers::Ollama.new, model: "qwen2.5:14b", cwd: Dir.pwd, tools: readonly_tools)
agent.run("Search the lib/ directory for any TODO or FIXME comments and summarize what you find.")

agent.message_store.messages.each { |msg| puts JSON.generate(msg) }
