#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only agent — restricted tool set, no write/patch/shell access.

require_relative "../lib/brute"
require "json"

readonly_tools = [
  Brute::Tools::FSRead,
  Brute::Tools::FSSearch,
  Brute::Tools::TodoRead,
  Brute::Tools::TodoWrite,
]

agent = Brute.agent(cwd: Dir.pwd, tools: readonly_tools)
agent.run("Search the lib/ directory for any TODO or FIXME comments and summarize what you find.")

agent.message_store.messages.each { |msg| puts JSON.generate(msg) }
