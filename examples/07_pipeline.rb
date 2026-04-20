#!/usr/bin/env ruby
# frozen_string_literal: true

# Rack-style middleware pipeline: wrap every LLM call with cross-cutting concerns.

require_relative "../lib/brute"

# A custom middleware that adds timing to every call
class TimingMiddleware < Brute::Middleware::Base
  def call(env)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = @app.call(env)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    env[:elapsed] = elapsed
    result
  end
end

# A terminal app that returns a synthetic response
class EchoTerminal
  def call(env)
    { content: "echo: #{env[:input]}" }
  end
end

pipeline = Brute::Pipeline.new do
  use TimingMiddleware
  run EchoTerminal.new
end

env = { input: "hello" }
result = pipeline.call(env)

puts result[:content]
