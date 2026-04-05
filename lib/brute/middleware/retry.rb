# frozen_string_literal: true

module Brute
  module Middleware
    # Retries the inner call on transient LLM errors with exponential backoff.
    #
    # Catches LLM::RateLimitError and LLM::ServerError, sleeps with
    # exponential delay, and re-calls the inner app. Non-retryable errors
    # propagate immediately.
    #
    # Unlike forgecode's separate retry.rs, this middleware wraps the LLM call
    # directly — it sees the error and retries without the orchestrator knowing.
    #
    class Retry < Base
      DEFAULT_MAX_ATTEMPTS = 3
      DEFAULT_BASE_DELAY = 2 # seconds

      def initialize(app, max_attempts: DEFAULT_MAX_ATTEMPTS, base_delay: DEFAULT_BASE_DELAY)
        super(app)
        @max_attempts = max_attempts
        @base_delay = base_delay
      end

      def call(env)
        attempts = 0
        begin
          @app.call(env)
        rescue LLM::RateLimitError, LLM::ServerError => e
          attempts += 1
          if attempts >= @max_attempts
            env[:metadata][:last_error] = e.message
            raise
          end

          delay = @base_delay ** attempts
          env[:metadata][:retry_attempt] = attempts
          env[:metadata][:retry_delay] = delay

          sleep(delay)
          retry
        end
      end
    end
  end
end
