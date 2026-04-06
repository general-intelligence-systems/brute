# frozen_string_literal: true

module Brute
  module Middleware
    # Logs timing and token usage for every LLM call, and tracks cumulative
    # timing data in env[:metadata][:timing].
    #
    # As the outermost middleware, it sees the full pipeline elapsed time per
    # call. It also tracks total wall-clock time across all calls in a turn
    # (including tool execution gaps between LLM calls).
    #
    # A new turn is detected when env[:tool_results] is nil (the orchestrator
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

        messages = env[:context].messages.to_a
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
