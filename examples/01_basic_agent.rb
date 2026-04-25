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

@session = Brute::Store::Session.new

step = Brute::Loop::AgentTurn.perform(
  agent: @agent,
  session: @session,
  pipeline: full_pipeline,
  callbacks: default_callbacks,
  input: "What files are in the current directory? List them.",
)

puts "\n\nDone (#{step.state})"
puts "Error: #{step.error}" if step.state == :failed
