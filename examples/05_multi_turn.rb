#!/usr/bin/env ruby
# frozen_string_literal: true

# Multi-turn — three turns in a sequential queue, shared session.

require_relative "helper"

provider_for_example :ollama

@session = Brute::Store::Session.new
@model   = "tinyllama"

agent = Brute::Agent.new(
  provider: @provider,
  model: @model,
  tools: Brute::Tools::ALL,
  system_prompt: system_prompt,
)

pipeline = full_pipeline

Sync do
  queue = Brute::Queue::SequentialQueue.new
  queue << Brute::Loop::AgentTurn.new(
    agent: agent, session: @session, pipeline: pipeline,
    callbacks: default_callbacks,
    input: "Create a file called config.yml with example settings for a web app: port, host, database_url, log_level.",
  )
  queue << Brute::Loop::AgentTurn.new(
    agent: agent, session: @session, pipeline: pipeline,
    callbacks: default_callbacks,
    input: "Change the port to 8080 and add a redis_url setting.",
  )
  queue << Brute::Loop::AgentTurn.new(
    agent: agent, session: @session, pipeline: pipeline,
    callbacks: default_callbacks,
    input: "Read config.yml and summarize all the settings.",
  )
  queue.start
  queue.drain

  queue.steps.each_with_index do |step, i|
    puts "\nTurn #{i + 1}: #{step.state}"
  end
end
