#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic agent — ask a question, get a response.

require_relative "helper"

@session = Brute::Store::Session.new

agent = Brute::Agent.new(
  provider: provider,
  model: nil,
  tools: Brute::Tools::ALL,
  system_prompt: system_prompt,
)

step = Brute::Loop::AgentTurn.perform(
  agent: agent,
  session: @session,
  pipeline: full_pipeline,
  input: "What files are in the current directory? List them.",
)

print_events
