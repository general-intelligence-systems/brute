# frozen_string_literal: true

require "bundler/setup"
require "brute"

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

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  def build_env(**overrides)
    { provider: MockProvider.new, model: nil, input: "test prompt", tools: [],
      messages: [], stream: nil, params: {}, metadata: {}, callbacks: {},
      tool_results: nil, streaming: false, should_exit: nil, pending_functions: [] }.merge(overrides)
  end

  def make_response
    MockResponse.new(content: "hello",
      usage: LLM::Usage.new(input_tokens: 100, output_tokens: 50, reasoning_tokens: 10, total_tokens: 160))
  end

  it "passes the response through unchanged" do
    response = make_response
    middleware = Brute::Middleware::TokenTracking.new(->(_env) { response })
    result = middleware.call(build_env)
    result.should == response
  end

  it "populates total_input tokens" do
    middleware = Brute::Middleware::TokenTracking.new(->(_env) { make_response })
    env = build_env
    middleware.call(env)
    env[:metadata][:tokens][:total_input].should == 100
  end

  it "populates total_output tokens" do
    middleware = Brute::Middleware::TokenTracking.new(->(_env) { make_response })
    env = build_env
    middleware.call(env)
    env[:metadata][:tokens][:total_output].should == 50
  end

  it "populates total_reasoning tokens" do
    middleware = Brute::Middleware::TokenTracking.new(->(_env) { make_response })
    env = build_env
    middleware.call(env)
    env[:metadata][:tokens][:total_reasoning].should == 10
  end

  it "populates call_count" do
    middleware = Brute::Middleware::TokenTracking.new(->(_env) { make_response })
    env = build_env
    middleware.call(env)
    env[:metadata][:tokens][:call_count].should == 1
  end

  it "accumulates token counts across multiple calls" do
    middleware = Brute::Middleware::TokenTracking.new(->(_env) { make_response })
    env = build_env
    middleware.call(env)
    middleware.call(env)
    env[:metadata][:tokens][:total_input].should == 200
  end

  it "handles a response without usage gracefully" do
    no_usage = Object.new
    middleware = Brute::Middleware::TokenTracking.new(->(_env) { no_usage })
    env = build_env
    middleware.call(env)
    env[:metadata][:tokens].should.be.nil
  end

  it "handles a response where usage returns nil" do
    nil_usage = Struct.new(:usage).new(nil)
    middleware = Brute::Middleware::TokenTracking.new(->(_env) { nil_usage })
    env = build_env
    middleware.call(env)
    env[:metadata][:tokens].should.be.nil
  end
end
