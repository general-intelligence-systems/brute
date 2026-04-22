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

  def build_env(**overrides)
    { provider: MockProvider.new, model: nil, input: "test prompt", tools: [],
      messages: [], stream: nil, params: {}, metadata: {}, callbacks: {},
      tool_results: nil, streaming: false, should_exit: nil, pending_functions: [] }.merge(overrides)
  end

  def mock_inner_app(response:)
    calls = []
    app = ->(env) { calls << env; response }
    [app, calls]
  end

  def flaky_inner_app(error_class, fail_count:, response:)
    attempt = 0
    ->(env) { attempt += 1; raise error_class, "transient" if attempt <= fail_count; response }
  end

  def no_sleep_retry(*args, **kwargs)
    mw = Brute::Middleware::Retry.new(*args, **kwargs)
    mw.define_singleton_method(:sleep) { |_| }
    mw
  end

  it "returns the response on first successful call" do
    response = MockResponse.new(content: "success")
    app, calls = mock_inner_app(response: response)
    middleware = Brute::Middleware::Retry.new(app)
    result = middleware.call(build_env)
    result.should == response
  end

  it "calls inner app exactly once on success" do
    response = MockResponse.new(content: "success")
    app, calls = mock_inner_app(response: response)
    Brute::Middleware::Retry.new(app).call(build_env)
    calls.size.should == 1
  end

  it "retries on LLM::RateLimitError and succeeds" do
    response = MockResponse.new(content: "success")
    app = flaky_inner_app(LLM::RateLimitError, fail_count: 2, response: response)
    middleware = no_sleep_retry(app, max_attempts: 3, base_delay: 2)
    env = build_env
    result = middleware.call(env)
    result.should == response
  end

  it "records retry_attempt in metadata after retries" do
    response = MockResponse.new(content: "success")
    app = flaky_inner_app(LLM::RateLimitError, fail_count: 2, response: response)
    middleware = no_sleep_retry(app, max_attempts: 3, base_delay: 2)
    env = build_env
    middleware.call(env)
    env[:metadata][:retry_attempt].should == 2
  end

  it "retries on LLM::ServerError and succeeds" do
    response = MockResponse.new(content: "success")
    app = flaky_inner_app(LLM::ServerError, fail_count: 1, response: response)
    middleware = no_sleep_retry(app, max_attempts: 3, base_delay: 2)
    result = middleware.call(build_env)
    result.should == response
  end

  it "re-raises after exhausting all attempts" do
    app = ->(_env) { raise LLM::RateLimitError, "rate limited" }
    middleware = no_sleep_retry(app, max_attempts: 3, base_delay: 2)
    lambda { middleware.call(build_env) }.should.raise(LLM::RateLimitError)
  end

  it "does not retry non-retryable errors" do
    call_count = 0
    app = ->(_env) { call_count += 1; raise ArgumentError, "bad input" }
    middleware = Brute::Middleware::Retry.new(app)
    lambda { middleware.call(build_env) }.should.raise(ArgumentError)
  end

  it "only calls inner app once for non-retryable errors" do
    call_count = 0
    app = ->(_env) { call_count += 1; raise ArgumentError, "bad input" }
    middleware = Brute::Middleware::Retry.new(app)
    begin; middleware.call(build_env); rescue ArgumentError; end
    call_count.should == 1
  end

  it "records retry_delay in metadata" do
    response = MockResponse.new(content: "success")
    app = flaky_inner_app(LLM::RateLimitError, fail_count: 1, response: response)
    middleware = no_sleep_retry(app, max_attempts: 3, base_delay: 3)
    env = build_env
    middleware.call(env)
    env[:metadata][:retry_delay].should == 3
  end

  it "tracks sleep delays for exponential backoff" do
    response = MockResponse.new(content: "success")
    app = flaky_inner_app(LLM::RateLimitError, fail_count: 2, response: response)
    delays = []
    mw = Brute::Middleware::Retry.new(app, max_attempts: 3, base_delay: 2)
    mw.define_singleton_method(:sleep) { |d| delays << d }
    mw.call(build_env)
    delays.should == [2, 4]
  end
end
