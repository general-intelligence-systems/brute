#!/usr/bin/env ruby
# frozen_string_literal: true

# System prompt: provider-aware prompt assembly with custom rules.

require_relative "../lib/brute"

prompt = Brute::SystemPrompt.new(
  cwd: Dir.pwd,
  tools: Brute::TOOLS,
  custom_rules: "Always use RSpec. Never use minitest.",
)

puts prompt.build
