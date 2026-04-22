#!/usr/bin/env ruby
# frozen_string_literal: true

# Custom rules — constrain agent behavior via AGENTS.md.
#
# Uses a local Ollama instance. Start Ollama first:
#   ollama serve
#   ollama pull qwen2.5:14b

require_relative "../lib/brute"
require "json"

dir = File.expand_path("tmp/custom_rules", __dir__)
FileUtils.mkdir_p(dir)

File.write("#{dir}/AGENTS.md", <<~MD)
  # Project Rules

  - All Ruby code MUST use frozen_string_literal comments.
  - Always use `snake_case` for method names.
  - Every class MUST have a one-line comment describing its purpose.
  - Use `raise ArgumentError` for invalid inputs, never `puts` an error.
MD

agent = Brute.agent(provider: Brute::Providers::Ollama.new, model: "qwen2.5:14b", cwd: dir)
agent.run(
  "Create a file called user.rb with a User class that has a name attribute " \
  "and a #greet method that returns a greeting string. Follow the project rules."
)

agent.message_store.messages.each { |msg| puts JSON.generate(msg) }

FileUtils.rm_rf(dir)
