# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Middleware
    # Logs timing and token usage for every LLM call, and tracks cumulative
    # timing data in env[:metadata][:timing].
    #
    # As the outermost middleware, it sees the full pipeline elapsed time per
    # call. It also tracks total wall-clock time across all calls in a turn
    # (including tool execution gaps between LLM calls).
    #
    # A new turn is detected when env[:tool_results] is nil (the agent loop
    # sets this on the first call of each run()).
    #
    # Stores in env[:metadata][:timing]:
    #   total_elapsed:     wall-clock since the turn began (includes tool gaps)
    #   total_llm_elapsed: cumulative time spent inside LLM calls only
    #   llm_call_count:    number of LLM calls so far
    #   last_call_elapsed: duration of the most recent LLM call
    #
    class Tracing < Base
      def initialize(app, logger:)
        super(app)
        @logger = logger
        @call_count = 0
        @total_llm_elapsed = 0.0
        @turn_start = nil
      end

      def call(env)
        @call_count += 1

        # Detect new turn: tool_results is nil on the first pipeline call
        if env[:tool_results].nil?
          @turn_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @total_llm_elapsed = 0.0
        end

        messages = env[:messages]
        @logger.debug("[brute] LLM call ##{@call_count} (#{messages.size} messages in context)")

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = @app.call(env)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = now - start

        @total_llm_elapsed += elapsed

        tokens = response.respond_to?(:usage) ? response.usage&.total_tokens : '?'
        @logger.info("[brute] LLM response ##{@call_count}: #{tokens} tokens, #{elapsed.round(2)}s")

        env[:metadata][:timing] = {
          total_elapsed: now - (@turn_start || start),
          total_llm_elapsed: @total_llm_elapsed,
          llm_call_count: @call_count,
          last_call_elapsed: elapsed
        }

        response
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Middleware::Tracing do
    let(:response) { MockResponse.new(content: "traced response") }
    let(:inner_app) { ->(_env) { response } }
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:middleware) { described_class.new(inner_app, logger: logger) }

    it "passes the response through unchanged" do
      env = build_env(tool_results: nil)
      result = middleware.call(env)
      expect(result).to eq(response)
    end

    it "populates env[:metadata][:timing] with all required keys" do
      env = build_env(tool_results: nil)
      middleware.call(env)

      timing = env[:metadata][:timing]
      expect(timing).to include(
        :total_elapsed,
        :total_llm_elapsed,
        :llm_call_count,
        :last_call_elapsed
      )
      expect(timing[:llm_call_count]).to eq(1)
      expect(timing[:last_call_elapsed]).to be >= 0
      expect(timing[:total_llm_elapsed]).to be >= 0
    end

    it "resets turn timing when tool_results is nil (new turn)" do
      env = build_env(tool_results: nil)
      middleware.call(env)
      first_elapsed = env[:metadata][:timing][:total_llm_elapsed]

      # Simulate continuation within the same turn (tool_results present)
      env[:tool_results] = [["read", { content: "file data" }]]
      middleware.call(env)

      expect(env[:metadata][:timing][:llm_call_count]).to eq(2)
      expect(env[:metadata][:timing][:total_llm_elapsed]).to be >= first_elapsed
    end

    it "accumulates call count across multiple calls" do
      env = build_env(tool_results: nil)
      middleware.call(env)
      env[:tool_results] = [["read", {}]]
      middleware.call(env)
      middleware.call(env)

      expect(env[:metadata][:timing][:llm_call_count]).to eq(3)
    end

    it "logs debug and info messages" do
      env = build_env(tool_results: nil)
      middleware.call(env)

      log_text = log_output.string
      expect(log_text).to include("LLM call #1")
      expect(log_text).to include("LLM response #1")
    end
  end
end
