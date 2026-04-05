#!/usr/bin/env ruby
# frozen_string_literal: true

# Test multi-step tool use: read, patch, verify.
# Requires: ANTHROPIC_API_KEY, OPENAI_API_KEY, or GOOGLE_API_KEY
# NOTE: May fail if the orchestrator's tool result handling doesn't match
# the provider's expected message format. This is a known integration area.

require_relative "../lib/brute"

DIR = File.expand_path("tmp/multi_tool_test", __dir__)
FileUtils.rm_rf(DIR)
FileUtils.mkdir_p(DIR)

File.write("#{DIR}/app.rb", <<~RUBY)
  class Calculator
    def add(a, b)
      a - b  # BUG: should be a + b
    end

    def subtract(a, b)
      a - b
    end
  end
RUBY

puts "=== 09: Agent Multi-Tool Test ==="
puts

tools_called = []
Brute.agent(
  cwd: DIR,
  on_content: ->(_) { },
  on_tool_call: ->(name, _) { tools_called << name },
  on_tool_result: ->(_, _) { },
).run(
  "There's a bug in app.rb — the add method subtracts instead of adding. " \
  "Read the file, fix the bug, then read it again to confirm."
).then do |_|
  puts "Tools called: #{tools_called.inspect}"
  puts "Used read: #{tools_called.include?("read") ? "yes" : "NO"}"
  puts "Used patch: #{tools_called.include?("patch") ? "yes" : "NO"}"
  puts

  File.read("#{DIR}/app.rb").then do |fixed|
    puts "File after fix:"
    fixed.lines.each { |l| puts "  #{l}" }
    puts
    puts "Bug fixed: #{fixed.include?("a + b") ? "yes" : "NO"}"
  end
end

FileUtils.rm_rf(DIR)
puts
puts "=== Multi-tool test completed ==="
