#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only agent — restricted tool set, no write/patch/shell access.

require_relative "helper"

provider_for_example :ollama

@session      = Brute::Store::Session.new
@model        = "tinyllama"
@tools        = [Brute::Tools::FSRead, Brute::Tools::FSSearch]
@custom_rules = "You are a read-only code analysis agent. You can read files and search but cannot modify anything."

agent = Brute::Agent.new(
  provider: @provider,
  model: @model,
  tools: @tools,
  system_prompt: system_prompt,
)

step = Brute::Loop::AgentTurn.perform(
  agent: agent,
  session: @session,
  pipeline: full_pipeline,
  callbacks: default_callbacks,
  input: "Search the lib/ directory for any TODO or FIXME comments and summarize what you find.",
)

puts "\n\nDone (#{step.state})"
puts "Error: #{step.error}" if step.state == :failed
