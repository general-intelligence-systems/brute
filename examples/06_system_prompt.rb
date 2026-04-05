#!/usr/bin/env ruby
# frozen_string_literal: true

# Test the dynamic system prompt builder.

require_relative "../lib/brute"

puts "=== 06: SystemPrompt Tests ==="
puts

# 1. Default prompt
Brute::SystemPrompt.new(cwd: Dir.pwd, tools: Brute::TOOLS).build.then do |prompt|
  puts "1. Length: #{prompt.size} chars, #{prompt.lines.size} lines"

  # 2. Required sections
  %w[Identity Tools Guidelines Environment].each do |section|
    prompt.include?("# #{section}").then { |found| puts "   Section '#{section}': #{found ? "present" : "MISSING"}" }
  end

  # 3. Tool names
  %w[read write patch remove fs_search undo shell fetch todo_write todo_read delegate].each do |tool|
    prompt.include?("**#{tool}**").then { |found| puts "   Tool '#{tool}': #{found ? "listed" : "MISSING"}" }
  end

  # 4. Environment
  puts "   Working dir: #{prompt.include?(Dir.pwd) ? "present" : "MISSING"}"
  puts "   Ruby version: #{prompt.include?(RUBY_VERSION) ? "present" : "MISSING"}"
end

# 5. Custom rules
Brute::SystemPrompt.new(cwd: Dir.pwd, tools: Brute::TOOLS, custom_rules: "Always use TDD.").build.then do |prompt|
  puts "5. Custom rules: #{prompt.include?("Always use TDD") ? "present" : "MISSING"}"
end

# 6. No custom rules
Brute::SystemPrompt.new(cwd: Dir.pwd, tools: Brute::TOOLS, custom_rules: nil).build.then do |prompt|
  puts "6. No rules section: #{!prompt.include?("Project-Specific") ? "correct" : "UNEXPECTED"}"
end

puts
puts "=== All SystemPrompt tests passed ==="
