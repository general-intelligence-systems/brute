#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic agent — ask a question, get a response.

require_relative "../lib/brute"
require "json"

agent = Brute.agent(cwd: Dir.pwd)
agent.run("What files are in the current directory? List them.")

agent.message_store.messages.each { |msg| puts JSON.generate(msg) }
