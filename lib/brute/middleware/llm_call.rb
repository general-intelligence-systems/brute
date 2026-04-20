# frozen_string_literal: true

module Brute
  module Middleware
    # The terminal "app" in the pipeline — performs the actual LLM call.
    #
    # When streaming, on_content fires incrementally via AgentStream.
    # When not streaming, fires on_content post-hoc with the full text.
    #
    class LLMCall
      def call(env)
        ctx = env[:context]
        response = ctx.talk(env[:input])

        # Only fire on_content post-hoc when NOT streaming
        # (streaming delivers chunks incrementally via AgentStream)
        unless env[:streaming]
          if (cb = env.dig(:callbacks, :on_content)) && response
            text = safe_content(response)
            cb.call(text) if text
          end
        end

        response
      end

      private

      # Safely extract text content from an LLM response.
      # Returns nil when the response contains only tool calls (no assistant text),
      # which causes LLM::Contract::Completion#content to raise NoMethodError
      # because messages.find(&:assistant?) returns nil.
      def safe_content(response)
        return nil unless response.respond_to?(:content)
        response.content
      rescue NoMethodError
        nil
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Middleware::LLMCall do
    let(:provider) { MockProvider.new }
    let(:middleware) { described_class.new }

    it "calls ctx.talk with env[:input] and returns the response" do
      ctx = LLM::Context.new(provider, tools: [])
      prompt = ctx.prompt { |p| p.system("sys"); p.user("hello") }
      env = build_env(context: ctx, provider: provider, input: prompt, streaming: false)

      response = middleware.call(env)

      expect(response).not_to be_nil
      expect(provider.calls.size).to eq(1)
    end

    context "when not streaming" do
      it "fires on_content callback with the response text" do
        received_content = nil
        callback = ->(text) { received_content = text }

        response = MockResponse.new(content: "Hello world")
        allow(provider).to receive(:complete).and_return(response)

        ctx = LLM::Context.new(provider, tools: [])
        prompt = ctx.prompt { |p| p.system("sys"); p.user("hi") }
        env = build_env(
          context: ctx,
          provider: provider,
          input: prompt,
          streaming: false,
          callbacks: { on_content: callback }
        )

        middleware.call(env)

        expect(received_content).to eq("Hello world")
      end
    end

    context "when streaming" do
      it "does not fire on_content callback" do
        callback_called = false
        callback = ->(_text) { callback_called = true }

        ctx = LLM::Context.new(provider, tools: [])
        prompt = ctx.prompt { |p| p.system("sys"); p.user("hi") }
        env = build_env(
          context: ctx,
          provider: provider,
          input: prompt,
          streaming: true,
          callbacks: { on_content: callback }
        )

        middleware.call(env)

        expect(callback_called).to be false
      end
    end

    context "when response content raises NoMethodError (tool-only response)" do
      it "does not crash and does not fire on_content" do
        received_content = :not_called
        callback = ->(text) { received_content = text }

        bad_response = MockResponse.new(content: "")
        allow(bad_response).to receive(:content).and_raise(NoMethodError)
        allow(provider).to receive(:complete).and_return(bad_response)

        ctx = LLM::Context.new(provider, tools: [])
        prompt = ctx.prompt { |p| p.system("sys"); p.user("hi") }
        env = build_env(
          context: ctx,
          provider: provider,
          input: prompt,
          streaming: false,
          callbacks: { on_content: callback }
        )

        expect { middleware.call(env) }.not_to raise_error
        expect(received_content).to eq(:not_called)
      end
    end
  end
end
