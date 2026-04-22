# frozen_string_literal: true

module Brute
  module Middleware
    # The terminal "app" in the pipeline — performs the actual LLM call.
    #
    # Builds a fresh LLM::Context per call from env[:messages], makes the
    # call, extracts new messages back into env[:messages], and stashes
    # pending functions in env[:pending_functions].
    #
    # When streaming, on_content fires incrementally via AgentStream.
    # When not streaming, fires on_content post-hoc with the full text.
    #
    class LLMCall
      def call(env)
        ctx = build_context(env)

        # Load existing conversation history into the ephemeral context
        ctx.messages.concat(env[:messages])

        response = ctx.talk(env[:input])

        # Extract new messages appended by talk() and store them
        new_messages = ctx.messages.to_a.drop(env[:messages].size)
        env[:messages].concat(new_messages)

        # Stash pending functions for the agent loop
        env[:pending_functions] = ctx.functions.to_a

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

      def build_context(env)
        params = {}
        params[:tools]  = env[:tools]   if env[:tools]&.any?
        params[:stream] = env[:stream]  if env[:stream]
        params[:model]  = env[:model]   if env[:model]
        LLM::Context.new(env[:provider], **params)
      end

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

    it "calls the provider and returns the response" do
      env = build_env(provider: provider, input: "hello", streaming: false)

      response = middleware.call(env)

      expect(response).not_to be_nil
      expect(provider.calls.size).to eq(1)
    end

    it "appends new messages to env[:messages]" do
      env = build_env(provider: provider, input: "hello", streaming: false)
      expect(env[:messages]).to be_empty

      middleware.call(env)

      expect(env[:messages]).not_to be_empty
    end

    it "populates env[:pending_functions]" do
      env = build_env(provider: provider, input: "hello", streaming: false)

      middleware.call(env)

      expect(env[:pending_functions]).to be_an(Array)
    end

    context "when not streaming" do
      it "fires on_content callback with the response text" do
        received_content = nil
        callback = ->(text) { received_content = text }

        response = MockResponse.new(content: "Hello world")
        allow(provider).to receive(:complete).and_return(response)

        env = build_env(
          provider: provider,
          input: "hi",
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

        env = build_env(
          provider: provider,
          input: "hi",
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

        env = build_env(
          provider: provider,
          input: "hi",
          streaming: false,
          callbacks: { on_content: callback }
        )

        expect { middleware.call(env) }.not_to raise_error
        expect(received_content).to eq(:not_called)
      end
    end

    it "preserves existing messages across calls" do
      existing_msg = LLM::Message.new(:user, "previous message")
      env = build_env(provider: provider, input: "hello", streaming: false, messages: [existing_msg])

      middleware.call(env)

      expect(env[:messages].first).to eq(existing_msg)
      expect(env[:messages].size).to be > 1
    end
  end
end
