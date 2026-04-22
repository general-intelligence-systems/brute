# frozen_string_literal: true

require "bundler/setup"
require "brute"

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

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  def build_env(**overrides)
    { provider: MockProvider.new, model: nil, input: "test prompt", tools: [],
      messages: [], stream: nil, params: {}, metadata: {}, callbacks: {},
      tool_results: nil, streaming: false, should_exit: nil, pending_functions: [] }.merge(overrides)
  end

  def make_middleware(app = nil)
    app ||= ->(_env) { MockResponse.new(content: "tracked") }
    Brute::Middleware::ToolErrorTracking.new(app, max_failures: 3)
  end

  it "passes the response through" do
    response = MockResponse.new(content: "tracked")
    app = ->(_env) { response }
    result = make_middleware(app).call(build_env)
    result.should == response
  end

  it "reports zero tool calls when tool_results is nil" do
    env = build_env(tool_results: nil)
    make_middleware.call(env)
    env[:metadata][:tool_calls].should == 0
  end

  it "reports empty tool errors when tool_results is nil" do
    env = build_env(tool_results: nil)
    make_middleware.call(env)
    env[:metadata][:tool_errors].should == {}
  end

  it "does not flag limit reached when tool_results is nil" do
    env = build_env(tool_results: nil)
    make_middleware.call(env)
    env[:metadata][:tool_error_limit_reached].should.be.false
  end

  it "counts total tool calls from tool_results" do
    results = [["fs_read", { content: "data" }], ["shell", { output: "ok" }], ["fs_write", { success: true }]]
    env = build_env(tool_results: results)
    make_middleware.call(env)
    env[:metadata][:tool_calls].should == 3
  end

  it "counts per-tool errors from results with error key" do
    results = [["fs_read", { error: "not found" }], ["fs_read", { error: "denied" }], ["shell", { output: "ok" }]]
    env = build_env(tool_results: results)
    make_middleware.call(env)
    env[:metadata][:tool_errors].should == { "fs_read" => 2 }
  end

  it "sets tool_error_limit_reached when a tool hits max_failures" do
    results = [["fs_read", { error: "1" }], ["fs_read", { error: "2" }], ["fs_read", { error: "3" }]]
    env = build_env(tool_results: results)
    make_middleware.call(env)
    env[:metadata][:tool_error_limit_reached].should.be.true
  end

  it "does not flag below the threshold" do
    results = [["fs_read", { error: "1" }], ["fs_read", { error: "2" }]]
    env = build_env(tool_results: results)
    make_middleware.call(env)
    env[:metadata][:tool_error_limit_reached].should.be.false
  end

  it "accumulates counts across multiple calls" do
    mw = make_middleware
    mw.call(build_env(tool_results: [["fs_read", { error: "fail" }]]))
    env2 = build_env(tool_results: [["fs_read", { error: "again" }], ["shell", { output: "ok" }]])
    mw.call(env2)
    env2[:metadata][:tool_calls].should == 3
  end

  it "clears counters on reset!" do
    mw = make_middleware
    mw.call(build_env(tool_results: [["fs_read", { error: "fail" }]]))
    mw.reset!
    env2 = build_env(tool_results: nil)
    mw.call(env2)
    env2[:metadata][:tool_calls].should == 0
  end

  it "sets should_exit reason when error limit reached" do
    results = [["fs_read", { error: "1" }], ["fs_read", { error: "2" }], ["fs_read", { error: "3" }]]
    env = build_env(tool_results: results)
    make_middleware.call(env)
    env[:should_exit][:reason].should == "tool_error_limit_reached"
  end

  it "sets should_exit source to ToolErrorTracking" do
    results = [["fs_read", { error: "1" }], ["fs_read", { error: "2" }], ["fs_read", { error: "3" }]]
    env = build_env(tool_results: results)
    make_middleware.call(env)
    env[:should_exit][:source].should == "ToolErrorTracking"
  end

  it "does not set should_exit below the threshold" do
    results = [["fs_read", { error: "1" }], ["fs_read", { error: "2" }]]
    env = build_env(tool_results: results)
    make_middleware.call(env)
    env[:should_exit].should.be.nil
  end

  it "does not overwrite should_exit if already set" do
    results = [["fs_read", { error: "1" }], ["fs_read", { error: "2" }], ["fs_read", { error: "3" }]]
    existing = { reason: "doom_loop_detected", message: "loop", source: "DoomLoopDetection" }
    env = build_env(tool_results: results, should_exit: existing)
    make_middleware.call(env)
    env[:should_exit][:reason].should == "doom_loop_detected"
  end
end
