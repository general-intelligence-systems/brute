# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Retries the inner call on transient LLM errors with exponential backoff.
    #
    # Catches LLM::RateLimitError and LLM::ServerError, sleeps with
    # exponential delay, and re-calls the inner app. Non-retryable errors
    # propagate immediately.
    #
    # Unlike forgecode's separate retry.rs, this middleware wraps the LLM call
    # directly — it sees the error and retries without the agent loop knowing.
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

          env[:callbacks].on_log("Retrying after #{e.class.name.split('::').last} (attempt #{attempts + 1}/#{@max_attempts}, waiting #{delay}s)...")
          sleep(delay)
          retry
        end
      end
    end
  end
end

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  it "returns the response on first successful call" do
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::Retry
      run ->(_env) { MockResponse.new(content: "success") }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    turn.result.content.should == "success"
  end

  it "retries on RateLimitError and records attempt count" do
    attempt = 0
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::Retry, max_attempts: 3, base_delay: 0
      run ->(env) {
        attempt += 1
        raise LLM::RateLimitError, "rate limited" if attempt <= 2
        MockResponse.new(content: "success")
      }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    turn.result.content.should == "success"
    turn.env[:metadata][:retry_attempt].should == 2
  end

  it "fails the step after exhausting all attempts" do
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::Retry, max_attempts: 2, base_delay: 0
      run ->(_env) { raise LLM::RateLimitError, "rate limited" }
    end

    step = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    step.state.should == :failed
    step.error.should.be.kind_of(LLM::RateLimitError)
  end

  it "does not retry non-retryable errors" do
    call_count = 0
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::Retry
      run ->(_env) { call_count += 1; raise ArgumentError, "bad" }
    end

    step = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    call_count.should == 1
    step.state.should == :failed
  end
end
