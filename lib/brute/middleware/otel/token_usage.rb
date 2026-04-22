# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    module OTel
      # Records token usage from the LLM response as span attributes.
      #
      # Runs POST-call: reads token counts from the response usage object
      # and sets them as attributes on the span.
      #
      class TokenUsage < Base
        def call(env)
          response = @app.call(env)

          span = env[:span]
          if span && response.respond_to?(:usage) && (usage = response.usage)
            span.set_attribute("gen_ai.usage.input_tokens", usage.input_tokens.to_i)
            span.set_attribute("gen_ai.usage.output_tokens", usage.output_tokens.to_i)
            span.set_attribute("gen_ai.usage.total_tokens", usage.total_tokens.to_i)

            reasoning = usage.reasoning_tokens.to_i
            span.set_attribute("gen_ai.usage.reasoning_tokens", reasoning) if reasoning > 0
          end

          response
        end
      end
    end
  end
end

test do
  require_relative "../../../../spec/support/mock_provider"
  require_relative "../../../../spec/support/mock_response"

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
    middleware = Brute::Middleware::OTel::TokenUsage.new(->(_env) { response })
    result = middleware.call(build_env)
    result.should == response
  end

  it "passes through without error when span is nil" do
    response = make_response
    middleware = Brute::Middleware::OTel::TokenUsage.new(->(_env) { response })
    lambda { middleware.call(build_env) }.should.not.raise
  end

  it "handles a response without usage gracefully" do
    no_usage = Object.new
    middleware = Brute::Middleware::OTel::TokenUsage.new(->(_env) { no_usage })
    lambda { middleware.call(build_env) }.should.not.raise
  end
end
