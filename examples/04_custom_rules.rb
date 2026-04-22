#!/usr/bin/env ruby
# frozen_string_literal: true

# Custom rules — constrain agent behavior via system prompt.

require_relative "helper"

provider_for_example :ollama

@session = Brute::Store::Session.new
@model   = "tinyllama"

@custom_rules = <<~RULES
  # Project Rules

  - All Ruby code MUST use frozen_string_literal comments.
  - Always use `snake_case` for method names.
  - Every class MUST have a one-line comment describing its purpose.
  - Use `raise ArgumentError` for invalid inputs, never `puts` an error.
RULES

agent = Brute::Agent.new(
  provider: @provider,
  model: @model,
  tools: Brute::Tools::ALL,
  system_prompt: system_prompt,
)

step = Brute::Loop::AgentTurn.perform(
  agent: agent,
  session: @session,
  pipeline: full_pipeline,
  input: "Create a file called user.rb with a User class that has a name attribute " \
         "and a #greet method that returns a greeting string. Follow the project rules.",
)

puts "State: #{step.state}"
if step.state == :completed
  puts step.result.content
else
  puts "Error: #{step.error}"
end
