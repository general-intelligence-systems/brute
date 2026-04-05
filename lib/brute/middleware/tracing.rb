# frozen_string_literal: true

module Brute
  module Middleware
    # Logs timing and token usage for every LLM call.
    #
    # Wraps the call with wall-clock timing. Logs:
    #   PRE:  request number, message count
    #   POST: elapsed time, token usage, finish reason
    #
    class Tracing < Base
      def initialize(app, logger:)
        super(app)
        @logger = logger
        @call_count = 0
      end

      def call(env)
        @call_count += 1
        messages = env[:context].messages.to_a
        @logger.debug("[brute] LLM call ##{@call_count} (#{messages.size} messages in context)")

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = @app.call(env)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

        tokens = response.respond_to?(:usage) ? response.usage&.total_tokens : "?"
        @logger.info("[brute] LLM response ##{@call_count}: #{tokens} tokens, #{elapsed.round(2)}s")

        response
      end
    end
  end
end
