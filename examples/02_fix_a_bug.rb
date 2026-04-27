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

agent = Brute::Agent.new(
  provider: Brute.provider,
  model:    "claude-sonnet-4-20250514",
  tools:    Brute::Tools::ALL,
) do
  use Brute::Middleware::EventHandler, handler_class: TerminalOutput
  use Brute::Middleware::SystemPrompt
  use Brute::Middleware::ToolResults
  use Brute::Middleware::MaxIterations
  use Brute::Middleware::ToolCall
  run Brute::Middleware::LLMCall.new
end

Brute::Session.new(path: File.join(__dir__, "tmp", "session_02.jsonl")).then do |session|
  session.user(
    "You are a coding assistant. Working directory: #{dir}\n\n" \
    "Read #{dir}/calculator.rb and #{dir}/calculator_test.rb. Fix the bugs so all tests pass, " \
    "then run `ruby #{dir}/calculator_test.rb` to verify."
  )
  agent.call(session)
  print_events(session)
end

FileUtils.rm_rf(dir)
