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

  # First call has no tool_results (new turn), so counts stay zero.
  turn = nil
  build_turn = -> {
    return turn if turn

    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::ToolErrorTracking, max_failures: 3
      run ->(_env) { MockResponse.new(content: "tracked") }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
  }

  it "returns the response unchanged" do
    build_turn.call
    turn.result.content.should == "tracked"
  end

  it "reports zero tool calls on a fresh turn" do
    build_turn.call
    turn.env[:metadata][:tool_calls].should == 0
  end

  it "does not flag error limit on a fresh turn" do
    build_turn.call
    turn.env[:metadata][:tool_error_limit_reached].should.be.false
  end

  it "sets should_exit when error limit reached via tool loop" do
    call_count = 0
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::ToolErrorTracking, max_failures: 2
      run ->(env) {
        call_count += 1
        # After first call, simulate tool results with errors
        if call_count < 4
          env[:tool_results_queue] = [Object.new]
          env[:tool_results] = [["fs_read", { error: "fail #{call_count}" }]]
        end
        MockResponse.new(content: "ok")
      }
    end

    step = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    step.env[:should_exit][:reason].should == "tool_error_limit_reached"
    step.env[:should_exit][:source].should == "ToolErrorTracking"
  end
end
