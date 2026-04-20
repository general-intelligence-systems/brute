#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple agent: one prompt, one response. Requires an API key.

require_relative "../lib/brute"

response = Brute.agent(cwd: Dir.pwd).run("What is 2 + 2? Reply with just the number.")
puts response.content.strip
