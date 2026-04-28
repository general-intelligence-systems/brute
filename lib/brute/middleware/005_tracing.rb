# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Logs timing and token usage for every LLM call, and tracks cumulative
    # timing data in env[:metadata][:timing].
    #
    # As the outermost middleware, it sees the full pipeline elapsed time per
    # call. It also tracks total wall-clock time across all calls in a turn
    # (including tool execution gaps between LLM calls).
    #
    # A new turn is detected when env[:current_iteration] == 1 (the agent
    # loop resets this at the start of each turn).
    #
    # Stores in env[:metadata][:timing]:
    #   total_elapsed:     wall-clock since the turn began (includes tool gaps)
    #   total_llm_elapsed: cumulative time spent inside LLM calls only
    #   llm_call_count:    number of LLM calls so far
    #   last_call_elapsed: duration of the most recent LLM call
    #
    class Tracing
      def initialize(app, logger:)
        @app = app

        @logger = logger
        @call_count = 0
        @total_llm_elapsed = 0.0
        @turn_start = nil
      end

      def call(env)
        @call_count += 1

        # Detect new turn via iteration counter
        if env[:current_iteration] <= 1
          @turn_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @total_llm_elapsed = 0.0
        end

        messages = env[:messages]
        provider_name = env[:provider]&.respond_to?(:name) ? env[:provider].name : env[:provider].class.name
        model_name = env[:model] || (env[:provider].default_model rescue "unknown")
        @logger.debug("[brute] LLM call ##{@call_count} [#{provider_name}/#{model_name}] (#{messages.size} messages in context)")

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = @app.call(env)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = now - start

        @total_llm_elapsed += elapsed

        tokens = if response.respond_to?(:usage) && (usage = response.usage)
          read_token(usage, :total_tokens)
        else
          '?'
        end
        @logger.debug("[brute] LLM response ##{@call_count} [#{provider_name}/#{model_name}]: #{tokens} tokens, #{elapsed.round(2)}s")
        env[:events] << { type: :log, data: "LLM response ##{@call_count}: #{tokens} tokens, #{elapsed.round(2)}s" } if response

        env[:metadata][:timing] = {
          total_elapsed: now - (@turn_start || start),
          total_llm_elapsed: @total_llm_elapsed,
          llm_call_count: @call_count,
          last_call_elapsed: elapsed
        }

        if response.respond_to?(:usage) && (u = response.usage)
          env[:metadata][:tokens] = {
            total:        read_token(u, :total_tokens),
            total_input:  read_token(u, :input_tokens),
            total_output: read_token(u, :output_tokens),
          }
        end

        response
      end

      private

      def read_token(usage, method)
        if usage.respond_to?(method)
          usage.send(method).to_i
        elsif usage.respond_to?(:[])
          (usage[method] || usage[method.to_s]).to_i
        else
          0
        end
      end
    end
  end
end
