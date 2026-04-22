# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Middleware
    # Tracks per-tool error counts and total tool call count across LLM
    # calls, and signals when the error ceiling is reached.
    #
    # This middleware doesn't execute tools itself — it inspects the tool
    # results that were sent as input to the LLM call (env[:tool_results])
    # and counts failures and totals.
    #
    # When any tool exceeds max_failures, it sets env[:metadata][:tool_error_limit_reached]
    # so the agent loop can decide to stop.
    #
    # Also stores env[:metadata][:tool_calls] with the cumulative number of
    # tool invocations in the current session.
    #
    class ToolErrorTracking < Base
      DEFAULT_MAX_FAILURES = 3

      def initialize(app, max_failures: DEFAULT_MAX_FAILURES)
        super(app)
        @max_failures = max_failures
        @errors = Hash.new(0) # tool_name → count
        @total_tool_calls = 0
      end

      def call(env)
        # PRE: count errors and totals from tool results that are about to be sent
        if (results = env[:tool_results])
          @total_tool_calls += results.size

          results.each do |name, result|
            @errors[name] += 1 if result.is_a?(Hash) && result[:error]
          end
        end

        env[:metadata][:tool_calls] = @total_tool_calls
        env[:metadata][:tool_errors] = @errors.dup
        env[:metadata][:tool_error_limit_reached] = @errors.any? { |_, c| c >= @max_failures }

        if env[:metadata][:tool_error_limit_reached]
          failed_tool, fail_count = @errors.max_by { |_, c| c }
          env[:should_exit] ||= {
            reason:  "tool_error_limit_reached",
            message: "Tool '#{failed_tool}' has failed #{fail_count} times (limit: #{@max_failures}). Stopping.",
            source:  "ToolErrorTracking",
          }
        end

        @app.call(env)
      end

      # Reset counts (e.g., between user turns).
      def reset!
        @errors.clear
        @total_tool_calls = 0
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Middleware::ToolErrorTracking do
    let(:response) { MockResponse.new(content: "tracked") }
    let(:inner_app) { ->(_env) { response } }
    let(:middleware) { described_class.new(inner_app, max_failures: 3) }

    it "passes the response through" do
      env = build_env
      result = middleware.call(env)
      expect(result).to eq(response)
    end

    it "reports zero tool calls when tool_results is nil" do
      env = build_env(tool_results: nil)
      middleware.call(env)

      expect(env[:metadata][:tool_calls]).to eq(0)
      expect(env[:metadata][:tool_errors]).to eq({})
      expect(env[:metadata][:tool_error_limit_reached]).to be false
    end

    it "counts total tool calls from tool_results" do
      results = [
        ["fs_read", { content: "data" }],
        ["shell", { output: "ok" }],
        ["fs_write", { success: true }],
      ]
      env = build_env(tool_results: results)
      middleware.call(env)

      expect(env[:metadata][:tool_calls]).to eq(3)
    end

    it "counts per-tool errors from results with error key" do
      results = [
        ["fs_read", { error: "not found" }],
        ["fs_read", { error: "permission denied" }],
        ["shell", { output: "ok" }],
      ]
      env = build_env(tool_results: results)
      middleware.call(env)

      expect(env[:metadata][:tool_errors]).to eq({ "fs_read" => 2 })
    end

    it "sets tool_error_limit_reached when a tool hits max_failures" do
      results = [
        ["fs_read", { error: "fail 1" }],
        ["fs_read", { error: "fail 2" }],
        ["fs_read", { error: "fail 3" }],
      ]
      env = build_env(tool_results: results)
      middleware.call(env)

      expect(env[:metadata][:tool_error_limit_reached]).to be true
    end

    it "does not flag below the threshold" do
      results = [
        ["fs_read", { error: "fail 1" }],
        ["fs_read", { error: "fail 2" }],
      ]
      env = build_env(tool_results: results)
      middleware.call(env)

      expect(env[:metadata][:tool_error_limit_reached]).to be false
    end

    it "accumulates counts across multiple calls" do
      env1 = build_env(tool_results: [["fs_read", { error: "fail" }]])
      middleware.call(env1)

      env2 = build_env(tool_results: [["fs_read", { error: "fail again" }], ["shell", { output: "ok" }]])
      middleware.call(env2)

      expect(env2[:metadata][:tool_calls]).to eq(3) # 1 + 2
      expect(env2[:metadata][:tool_errors]).to eq({ "fs_read" => 2 })
    end

    it "clears counters on reset!" do
      env = build_env(tool_results: [["fs_read", { error: "fail" }]])
      middleware.call(env)

      middleware.reset!

      env2 = build_env(tool_results: nil)
      middleware.call(env2)

      expect(env2[:metadata][:tool_calls]).to eq(0)
      expect(env2[:metadata][:tool_errors]).to eq({})
    end

    # -- should_exit signal --

    it "sets env[:should_exit] when the error limit is reached" do
      results = [
        ["fs_read", { error: "fail 1" }],
        ["fs_read", { error: "fail 2" }],
        ["fs_read", { error: "fail 3" }],
      ]
      env = build_env(tool_results: results)
      middleware.call(env)

      expect(env[:should_exit]).to be_a(Hash)
      expect(env[:should_exit][:reason]).to eq("tool_error_limit_reached")
      expect(env[:should_exit][:source]).to eq("ToolErrorTracking")
      expect(env[:should_exit][:message]).to include("fs_read")
      expect(env[:should_exit][:message]).to include("3 times")
    end

    it "does not set env[:should_exit] below the threshold" do
      results = [
        ["fs_read", { error: "fail 1" }],
        ["fs_read", { error: "fail 2" }],
      ]
      env = build_env(tool_results: results)
      middleware.call(env)

      expect(env[:should_exit]).to be_nil
    end

    it "does not overwrite env[:should_exit] if already set (first-writer-wins)" do
      results = [
        ["fs_read", { error: "fail 1" }],
        ["fs_read", { error: "fail 2" }],
        ["fs_read", { error: "fail 3" }],
      ]
      existing_exit = { reason: "doom_loop_detected", message: "loop", source: "DoomLoopDetection" }
      env = build_env(tool_results: results, should_exit: existing_exit)
      middleware.call(env)

      expect(env[:should_exit][:reason]).to eq("doom_loop_detected")
      expect(env[:should_exit][:source]).to eq("DoomLoopDetection")
    end
  end
end
