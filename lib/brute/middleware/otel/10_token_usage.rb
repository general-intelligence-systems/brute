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

  it "passes the response through unchanged" do
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::OTel::TokenUsage
      run ->(_env) {
        MockResponse.new(content: "hello",
          usage: LLM::Usage.new(input_tokens: 100, output_tokens: 50, reasoning_tokens: 10, total_tokens: 160))
      }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    turn.result.content.should == "hello"
  end

  it "handles a response without usage gracefully" do
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::OTel::TokenUsage
      run ->(_env) { Object.new }
    end

    step = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    step.state.should == :completed
  end
end
