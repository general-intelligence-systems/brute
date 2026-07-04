#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic agent — loaded from a brute.ru file.
#
# Identical behaviour to 01_basic_agent, but the agent is described in a
# separate brute.ru (a rackup-style config) and loaded with
# Brute::Turn::AgentPipeline.parse_file, rather than built inline. This is the
# Brute analogue of `rackup config.ru`.
#
# Defaults to a local Ollama (see docker-compose.yml). Override with env vars:
#   BRUTE_PROVIDER=anthropic BRUTE_MODEL=claude-sonnet-4-20250514 ANTHROPIC_API_KEY=... ruby examples/agents/01c_brute_ru.rb

require_relative "helper"

agent = Brute::Turn::AgentPipeline.parse_file(File.join(__dir__, "brute.ru"))

env = agent.start("What files are in the current directory? List them.")
print_events(env[:messages])
