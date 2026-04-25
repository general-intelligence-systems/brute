#!/usr/bin/env ruby
# frozen_string_literal: true

# Session persistence — two turns share the same session.

require_relative "helper"

provider_for_example :ollama

@session = Brute::Store::Session.new
@model   = "tinyllama"

agent = Brute::Agent.new(
  provider: @provider,
  model: @model,
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
  callbacks: default_callbacks,
  input: "Remember this: the secret project codename is FALCON. Just acknowledge.",
)
puts "\nTurn 1: #{step1.state}"

# Second turn — same session, ask it back
puts "\n=== Turn 2 ==="
step2 = Brute::Loop::AgentTurn.perform(
  agent: agent,
  session: @session,
  pipeline: pipeline,
  callbacks: default_callbacks,
  input: "What is the secret project codename I told you?",
)
puts "\nTurn 2: #{step2.state}"

@session.delete
