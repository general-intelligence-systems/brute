#!/usr/bin/env ruby
# frozen_string_literal: true

# Single AgentTurn — one prompt, tool loop, done.

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

step = Brute::Loop::AgentTurn.perform(
  agent: agent,
  session: @session,
  pipeline: full_pipeline,
  input: "What is 2 + 2?",
)

puts "State: #{step.state}"
if step.state == :completed
  puts "Response: #{step.result.content}"
else
  puts "Error: #{step.error}"
end
