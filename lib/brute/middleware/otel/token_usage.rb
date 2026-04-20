# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

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

if __FILE__ == $0
  require_relative "../../../../spec/spec_helper"

  RSpec.describe Brute::Middleware::OTel::TokenUsage do
    let(:response) do
      MockResponse.new(
        content: "hello",
        usage: LLM::Usage.new(input_tokens: 100, output_tokens: 50, reasoning_tokens: 10, total_tokens: 160)
      )
    end
    let(:inner_app) { ->(_env) { response } }
    let(:middleware) { described_class.new(inner_app) }

    it "passes the response through unchanged" do
      env = build_env
      result = middleware.call(env)
      expect(result).to eq(response)
    end

    context "when env[:span] is nil" do
      it "passes through without error" do
        env = build_env
        result = middleware.call(env)
        expect(result).to eq(response)
      end
    end

    context "when env[:span] is present" do
      let(:span) { mock_span }

      it "sets token usage attributes on the span" do
        env = build_env(span: span)
        middleware.call(env)

        expect(span).to have_received(:set_attribute).with("gen_ai.usage.input_tokens", 100)
        expect(span).to have_received(:set_attribute).with("gen_ai.usage.output_tokens", 50)
        expect(span).to have_received(:set_attribute).with("gen_ai.usage.total_tokens", 160)
      end

      it "sets reasoning_tokens when greater than zero" do
        env = build_env(span: span)
        middleware.call(env)

        expect(span).to have_received(:set_attribute).with("gen_ai.usage.reasoning_tokens", 10)
      end

      it "omits reasoning_tokens when zero" do
        zero_reasoning = MockResponse.new(
          content: "hello",
          usage: LLM::Usage.new(input_tokens: 100, output_tokens: 50, reasoning_tokens: 0, total_tokens: 150)
        )
        app = ->(_env) { zero_reasoning }
        mw = described_class.new(app)
        env = build_env(span: span)

        mw.call(env)

        expect(span).not_to have_received(:set_attribute).with("gen_ai.usage.reasoning_tokens", anything)
      end

      it "handles a response without usage gracefully" do
        no_usage = double("response")
        allow(no_usage).to receive(:respond_to?).with(:usage).and_return(false)
        app = ->(_env) { no_usage }
        mw = described_class.new(app)
        env = build_env(span: span)

        result = mw.call(env)

        expect(result).to eq(no_usage)
        expect(span).not_to have_received(:set_attribute)
      end

      it "handles a response where usage returns nil" do
        nil_usage = double("response", usage: nil)
        allow(nil_usage).to receive(:respond_to?).with(:usage).and_return(true)
        app = ->(_env) { nil_usage }
        mw = described_class.new(app)
        env = build_env(span: span)

        mw.call(env)

        expect(span).not_to have_received(:set_attribute)
      end
    end
  end
end
