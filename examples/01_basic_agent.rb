#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic agent — ask a question, get a response.

require_relative "helper"

provider_for_example :ollama

@model = "tinyllama"

@agent = Brute::Agent.new(
  provider: @provider,
  model: @model,
  tools: Brute::Tools::ALL,
  system_prompt: system_prompt,
)

Brute::Store::Session.new.then do |session|
  Brute::Loop::AgentTurn.perform(
    agent: @agent,
    session: session,
    pipeline: full_pipeline,
    input: "What files are in the current directory? List them.",
  )
end

puts "State: #{step.state}"
if step.state == :completed
  puts step.result.content
else
  puts "Error: #{step.error}"
end
