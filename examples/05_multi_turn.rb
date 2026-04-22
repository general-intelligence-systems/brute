#!/usr/bin/env ruby
# frozen_string_literal: true

# Multi-turn — multiple .run() calls on the same agent, full context retained.

require_relative "../lib/brute"
require "json"

dir = File.expand_path("tmp/multi_turn", __dir__)
FileUtils.mkdir_p(dir)

agent = Brute.agent(cwd: dir)

agent.run(
  "Create a file called config.yml with example settings for a web app: " \
  "port, host, database_url, log_level."
)

agent.run("Change the port to 8080 and add a redis_url setting.")

agent.run("Read config.yml and summarize all the settings.")

agent.message_store.messages.each { |msg| puts JSON.generate(msg) }

FileUtils.rm_rf(dir)
