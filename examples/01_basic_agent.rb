#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic agent — ask a question, get a response.
#
# Uses a local Ollama instance. Start Ollama first:
#   ollama serve
#   ollama pull qwen2.5:14b

require_relative "../lib/brute"
require "json"

agent = Brute.agent(provider: Brute::Providers::Ollama.new, model: "qwen2.5:14b", cwd: Dir.pwd)
agent.run("What files are in the current directory? List them.")

agent.message_store.messages.each { |msg| puts JSON.generate(msg) }
