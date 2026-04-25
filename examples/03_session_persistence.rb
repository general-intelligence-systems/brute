#!/usr/bin/env ruby
# frozen_string_literal: true

# Session persistence — two turns share the same session.

require_relative "helper"

@session = Brute::Store::Session.new

agent = Brute::Agent.new(
  provider: provider,
  model: nil,
  tools: [],
  system_prompt: system_prompt,
)

pipeline = full_pipeline

# First turn — tell it something
puts "=== Turn 1 ==="
step1 = Brute::Loop::AgentTurn.perform(
  agent: agent,
  session: @session,
  pipeline: pipeline,
  input: "Remember this: the secret project codename is FALCON. Just acknowledge.",
)
# Second turn — same session, ask it back
puts "\n=== Turn 2 ==="
step2 = Brute::Loop::AgentTurn.perform(
  agent: agent,
  session: @session,
  pipeline: pipeline,
  input: "What is the secret project codename I told you?",
)

print_events

@session.delete
