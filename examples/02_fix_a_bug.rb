#!/usr/bin/env ruby
# frozen_string_literal: true

# Fix a bug — agent reads a buggy file, patches it, and verifies.

require_relative "helper"

dir = File.expand_path("tmp/fix_a_bug", __dir__)
FileUtils.mkdir_p(dir)

File.write("#{dir}/calculator.rb", <<~RUBY)
  class Calculator
    def add(a, b)
      a - b
    end

    def multiply(a, b)
      a + b
    end
  end
RUBY

File.write("#{dir}/calculator_test.rb", <<~RUBY)
  require_relative "calculator"

  calc = Calculator.new
  raise "add is broken"      unless calc.add(2, 3) == 5
  raise "multiply is broken" unless calc.multiply(4, 5) == 20

  puts "All tests pass!"
RUBY

@session      = Brute::Store::Session.new
@custom_rules = "You are a coding assistant. Fix bugs in the code. Working directory: #{dir}"

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
  input: "Read calculator.rb and calculator_test.rb. Fix the bugs so all tests pass, " \
         "then run `ruby calculator_test.rb` to verify.",
)

puts @session.message_store.messages

FileUtils.rm_rf(dir)
