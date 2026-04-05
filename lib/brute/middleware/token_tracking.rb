# frozen_string_literal: true

module Brute
  module Middleware
    # Tracks cumulative token usage across all LLM calls in a session.
    #
    # Runs POST-call: reads usage from the response and accumulates totals
    # in env[:metadata]. Also records per-call usage for the most recent call.
    #
    class TokenTracking < Base
      def initialize(app)
        super(app)
        @total_input = 0
        @total_output = 0
        @total_reasoning = 0
        @call_count = 0
      end

      def call(env)
        response = @app.call(env)

        if response.respond_to?(:usage) && (usage = response.usage)
          @total_input += usage.input_tokens.to_i
          @total_output += usage.output_tokens.to_i
          @total_reasoning += usage.reasoning_tokens.to_i
          @call_count += 1

          env[:metadata][:tokens] = {
            total_input: @total_input,
            total_output: @total_output,
            total_reasoning: @total_reasoning,
            total: @total_input + @total_output,
            call_count: @call_count,
            last_call: {
              input: usage.input_tokens.to_i,
              output: usage.output_tokens.to_i,
              total: usage.total_tokens.to_i,
            },
          }
        end

        response
      end
    end
  end
end
