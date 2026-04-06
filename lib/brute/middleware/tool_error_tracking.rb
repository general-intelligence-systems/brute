# frozen_string_literal: true

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
    # so the orchestrator can decide to stop.
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
