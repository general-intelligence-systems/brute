#!/usr/bin/env ruby
# frozen_string_literal: true

# Fix a bug — agent reads a buggy file, patches it, and verifies.
#
# Uses a local Ollama instance. Start Ollama first:
#   ollama serve
#   ollama pull qwen2.5:14b

require_relative "../lib/brute"
require "json"

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

agent = Brute.agent(provider: Brute::Providers::Ollama.new, model: "qwen2.5:14b", cwd: dir)
agent.run(
  "Read calculator.rb and calculator_test.rb. Fix the bugs so all tests pass, " \
  "then run `ruby calculator_test.rb` to verify."
)

agent.message_store.messages.each { |msg| puts JSON.generate(msg) }

FileUtils.rm_rf(dir)
