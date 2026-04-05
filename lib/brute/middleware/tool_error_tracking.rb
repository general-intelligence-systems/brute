# frozen_string_literal: true

module Brute
  module Middleware
    # Tracks per-tool error counts across LLM calls and signals when
    # the error ceiling is reached.
    #
    # This middleware doesn't execute tools itself — it inspects the tool
    # results that were sent as input to the LLM call (env[:tool_results])
    # and counts failures.
    #
    # When any tool exceeds max_failures, it sets env[:metadata][:tool_error_limit_reached]
    # so the orchestrator can decide to stop.
    #
    class ToolErrorTracking < Base
      DEFAULT_MAX_FAILURES = 3

      def initialize(app, max_failures: DEFAULT_MAX_FAILURES)
        super(app)
        @max_failures = max_failures
        @errors = Hash.new(0) # tool_name → count
      end

      def call(env)
        # PRE: count errors from tool results that are about to be sent
        if (results = env[:tool_results])
          results.each do |name, result|
            if result.is_a?(Hash) && result[:error]
              @errors[name] += 1
            end
          end
        end

        env[:metadata][:tool_errors] = @errors.dup
        env[:metadata][:tool_error_limit_reached] = @errors.any? { |_, c| c >= @max_failures }

        @app.call(env)
      end

      # Reset error counts (e.g., between user turns).
      def reset!
        @errors.clear
      end
    end
  end
end
