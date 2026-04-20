# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

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

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Middleware::TokenTracking do
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

    it "populates env[:metadata][:tokens] with correct values" do
      env = build_env
      middleware.call(env)

      tokens = env[:metadata][:tokens]
      expect(tokens[:total_input]).to eq(100)
      expect(tokens[:total_output]).to eq(50)
      expect(tokens[:total_reasoning]).to eq(10)
      expect(tokens[:total]).to eq(150) # input + output
      expect(tokens[:call_count]).to eq(1)
      expect(tokens[:last_call]).to eq(input: 100, output: 50, total: 160)
    end

    it "accumulates token counts across multiple calls" do
      env = build_env
      middleware.call(env)
      middleware.call(env)

      tokens = env[:metadata][:tokens]
      expect(tokens[:total_input]).to eq(200)
      expect(tokens[:total_output]).to eq(100)
      expect(tokens[:total_reasoning]).to eq(20)
      expect(tokens[:call_count]).to eq(2)
    end

    it "handles a response without usage gracefully" do
      no_usage_response = double("response")
      allow(no_usage_response).to receive(:respond_to?).with(:usage).and_return(false)
      app = ->(_env) { no_usage_response }
      mw = described_class.new(app)

      env = build_env
      result = mw.call(env)

      expect(result).to eq(no_usage_response)
      expect(env[:metadata][:tokens]).to be_nil
    end

    it "handles a response where usage returns nil" do
      nil_usage_response = double("response", usage: nil)
      allow(nil_usage_response).to receive(:respond_to?).with(:usage).and_return(true)
      app = ->(_env) { nil_usage_response }
      mw = described_class.new(app)

      env = build_env
      mw.call(env)

      expect(env[:metadata][:tokens]).to be_nil
    end
  end
end
