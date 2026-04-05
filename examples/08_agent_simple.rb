#!/usr/bin/env ruby
# frozen_string_literal: true

# Test the orchestrator with a real LLM call.
# Requires: ANTHROPIC_API_KEY, OPENAI_API_KEY, or GOOGLE_API_KEY

require_relative "../lib/brute"

puts "=== 08: Agent Simple Test ==="
puts

# 1. Basic prompt
puts "[1] Simple question (no tools)"
Brute.agent(cwd: Dir.pwd).run("What is 2 + 2? Reply with just the number.").then do |response|
  puts "   Response: #{response&.content&.strip}"
  puts "   Has content: #{response&.content ? "yes" : "NO"}"
end
puts

# 2. Tool use
puts "[2] Read a file"
FileUtils.mkdir_p("tmp/agent_test")
File.write("tmp/agent_test/sample.txt", "The secret number is 42.")

Brute.agent(cwd: Dir.pwd).run("Read the file tmp/agent_test/sample.txt and tell me the secret number.").then do |response|
  puts "   Response: #{response&.content&.strip&.lines&.first}"
  puts "   Contains 42: #{response&.content&.include?("42") ? "yes" : "NO"}"
end
puts

# 3. Callbacks
puts "[3] Callbacks"
tools_called = []
Brute.agent(
  cwd: Dir.pwd,
  on_content: ->(_) { },
  on_tool_call: ->(name, _) { tools_called << name },
  on_tool_result: ->(_, _) { },
).run("List files in the current directory using the shell tool. Run 'ls'.").then do |_|
  puts "   Tools called: #{tools_called.inspect}"
  puts "   Shell used: #{tools_called.include?("shell") ? "yes" : "maybe not (LLM choice)"}"
end

FileUtils.rm_rf("tmp/agent_test")
puts
puts "=== Agent simple tests completed ==="
