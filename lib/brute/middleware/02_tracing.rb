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
    # A new turn is detected when env[:tool_results] is nil (the agent loop
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

        messages = env[:messages]
        provider_name = env[:provider]&.respond_to?(:name) ? env[:provider].name : env[:provider].class.name
        model_name = env[:model] || (env[:provider].default_model rescue "unknown")
        @logger.debug("[brute] LLM call ##{@call_count} [#{provider_name}/#{model_name}] (#{messages.size} messages in context)")
        env[:callbacks][:on_log]&.call("LLM call ##{@call_count} [#{provider_name}/#{model_name}] (#{messages.size} messages)")

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = @app.call(env)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        elapsed = now - start

        @total_llm_elapsed += elapsed

        tokens = response.respond_to?(:usage) ? response.usage&.total_tokens : '?'
        @logger.debug("[brute] LLM response ##{@call_count} [#{provider_name}/#{model_name}]: #{tokens} tokens, #{elapsed.round(2)}s")
        env[:callbacks][:on_log]&.call("LLM response ##{@call_count}: #{tokens} tokens, #{elapsed.round(2)}s") if response

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

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  def build_env(**overrides)
    { provider: MockProvider.new, model: nil, input: "test prompt", tools: [],
      messages: [], stream: nil, params: {}, metadata: {}, callbacks: {},
      tool_results: nil, streaming: false, should_exit: nil, pending_functions: [] }.merge(overrides)
  end

  it "passes the response through unchanged" do
    response = MockResponse.new(content: "traced response")
    inner_app = ->(_env) { response }
    middleware = Brute::Middleware::Tracing.new(inner_app, logger: Logger.new(StringIO.new))
    result = middleware.call(build_env(tool_results: nil))
    result.should == response
  end

  it "populates timing with llm_call_count" do
    response = MockResponse.new(content: "traced response")
    inner_app = ->(_env) { response }
    middleware = Brute::Middleware::Tracing.new(inner_app, logger: Logger.new(StringIO.new))
    env = build_env(tool_results: nil)
    middleware.call(env)
    env[:metadata][:timing][:llm_call_count].should == 1
  end

  it "populates timing with non-negative last_call_elapsed" do
    response = MockResponse.new(content: "traced response")
    inner_app = ->(_env) { response }
    middleware = Brute::Middleware::Tracing.new(inner_app, logger: Logger.new(StringIO.new))
    env = build_env(tool_results: nil)
    middleware.call(env)
    (env[:metadata][:timing][:last_call_elapsed] >= 0).should.be.true
  end

  it "accumulates call count across multiple calls" do
    response = MockResponse.new(content: "traced response")
    inner_app = ->(_env) { response }
    middleware = Brute::Middleware::Tracing.new(inner_app, logger: Logger.new(StringIO.new))
    env = build_env(tool_results: nil)
    middleware.call(env)
    env[:tool_results] = [["read", {}]]
    middleware.call(env)
    middleware.call(env)
    env[:metadata][:timing][:llm_call_count].should == 3
  end

  it "logs LLM call and response messages" do
    response = MockResponse.new(content: "traced response")
    inner_app = ->(_env) { response }
    log_output = StringIO.new
    middleware = Brute::Middleware::Tracing.new(inner_app, logger: Logger.new(log_output))
    middleware.call(build_env(tool_results: nil))
    log_output.string.should =~ /LLM call #1/
  end

  it "fires on_log callback for pre-call and post-call" do
    response = MockResponse.new(content: "traced response")
    inner_app = ->(_env) { response }
    log_messages = []
    callbacks = { on_log: ->(text) { log_messages << text } }
    middleware = Brute::Middleware::Tracing.new(inner_app, logger: Logger.new(StringIO.new))
    middleware.call(build_env(tool_results: nil, callbacks: callbacks))
    log_messages.size.should == 2
    log_messages[0].should =~ /LLM call #1/
    log_messages[1].should =~ /LLM response #1/
  end
end
