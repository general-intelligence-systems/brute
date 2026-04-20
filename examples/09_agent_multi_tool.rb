#!/usr/bin/env ruby
# frozen_string_literal: true

# Multi-tool agent: reads a buggy file, fixes it, verifies. Requires an API key.

require_relative "../lib/brute"

dir = File.expand_path("tmp/multi_tool_example", __dir__)
FileUtils.mkdir_p(dir)

File.write("#{dir}/app.rb", <<~RUBY)
  class Calculator
    def add(a, b)
      a - b  # BUG: should be a + b
    end
  end
RUBY

Brute.agent(cwd: dir).run(
  "There's a bug in app.rb -- the add method subtracts instead of adding. " \
  "Read the file, fix the bug, then read it again to confirm."
)

puts File.read("#{dir}/app.rb")

FileUtils.rm_rf(dir)
