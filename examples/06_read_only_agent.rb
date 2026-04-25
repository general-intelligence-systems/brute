#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only agent — restricted tool set, no write/patch/shell access.

require_relative "helper"

@session      = Brute::Store::Session.new
@tools        = [Brute::Tools::FSRead, Brute::Tools::FSSearch]
@custom_rules = "You are a read-only code analysis agent. You can read files and search but cannot modify anything."

agent = Brute::Agent.new(
  provider: provider,
  model: nil,
  tools: @tools,
  system_prompt: system_prompt,
)

step = Brute::Loop::AgentTurn.perform(
  agent: agent,
  session: @session,
  pipeline: full_pipeline,
  input: "Search the lib/ directory for any TODO or FIXME comments and summarize what you find.",
)

puts @session.message_store.messages
