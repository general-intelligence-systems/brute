# frozen_string_literal: true
#
# Serve a Brute agent over HTTP. This is a real rackup config.ru: it loads the
# agent described in brute.ru and wraps it in Brute::Rack::Adapter, which turns
# each incoming Rack env into a prompt string and the agent's reply into a Rack
# `[status, headers, body]` response.
#
#   rackup examples/agents/config.ru          # or: falcon serve -c config.ru
#
#   curl -d 'What files are here? List them.' localhost:9292
#   curl -H 'content-type: application/json' -d '{"prompt":"hi"}' localhost:9292
#   curl 'localhost:9292/?prompt=hi'
#
# Provider/model config lives in brute.ru's terminal `run` proc; see that file.

require_relative "helper"

agent = Brute::Turn::AgentPipeline.parse_file(File.join(__dir__, "brute.ru"))

run Brute::Rack::Adapter.for(agent)
