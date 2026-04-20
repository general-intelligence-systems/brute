# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Middleware
    # Detects when the agent is stuck repeating tool call patterns and injects
    # a corrective warning into the context before the next LLM call.
    #
    # Runs PRE-call: inspects the conversation history for repeating tool call
    # patterns. If detected, talks a warning message into the context so the
    # LLM sees it as input alongside the normal tool results.
    #
    class DoomLoopDetection < Base
      def initialize(app, threshold: 3)
        super(app)
        @detector = Brute::DoomLoopDetector.new(threshold: threshold)
      end

      def call(env)
        ctx = env[:context]
        messages = ctx.messages.to_a

        if (reps = @detector.detect(messages))
          warning = @detector.warning_message(reps)
          # Inject the warning as a user message so the LLM sees it
          ctx.talk(warning)
          env[:metadata][:doom_loop_detected] = reps
        end

        @app.call(env)
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Middleware::DoomLoopDetection do
    let(:response) { MockResponse.new(content: "loop check") }
    let(:inner_app) { ->(_env) { response } }

    # Build a fake assistant message whose .functions returns the given list.
    def assistant_msg_with_functions(function_list)
      msg = LLM::Message.new(:assistant, "tool msg", {})
      allow(msg).to receive(:functions).and_return(function_list)
      msg
    end

    def fake_function(name:, arguments:)
      double("fn", name: name, arguments: arguments)
    end

    it "passes through when no doom loop is detected" do
      middleware = described_class.new(inner_app, threshold: 3)
      env = build_env

      result = middleware.call(env)

      expect(result).to eq(response)
      expect(env[:metadata][:doom_loop_detected]).to be_nil
    end

    it "detects consecutive identical tool calls" do
      provider = MockProvider.new
      ctx = LLM::Context.new(provider, tools: [])

      fn = fake_function(name: "fs_read", arguments: '{"path":"x.rb"}')
      messages = 4.times.map { assistant_msg_with_functions([fn]) }

      allow(ctx).to receive(:messages).and_return(double("buffer", to_a: messages))
      allow(ctx).to receive(:talk)

      middleware = described_class.new(inner_app, threshold: 3)
      env = build_env(context: ctx, provider: provider)

      middleware.call(env)

      expect(env[:metadata][:doom_loop_detected]).not_to be_nil
    end

    it "detects repeating sequences [A,B,A,B,A,B]" do
      provider = MockProvider.new
      ctx = LLM::Context.new(provider, tools: [])

      fn_a = fake_function(name: "fs_read", arguments: '{"path":"a.rb"}')
      fn_b = fake_function(name: "shell", arguments: '{"cmd":"ls"}')
      messages = 3.times.flat_map do
        [assistant_msg_with_functions([fn_a]), assistant_msg_with_functions([fn_b])]
      end

      allow(ctx).to receive(:messages).and_return(double("buffer", to_a: messages))
      allow(ctx).to receive(:talk)

      middleware = described_class.new(inner_app, threshold: 3)
      env = build_env(context: ctx, provider: provider)

      middleware.call(env)

      expect(env[:metadata][:doom_loop_detected]).not_to be_nil
    end

    it "does not trigger below the threshold" do
      provider = MockProvider.new
      ctx = LLM::Context.new(provider, tools: [])

      fn = fake_function(name: "fs_read", arguments: '{"path":"x.rb"}')
      messages = 2.times.map { assistant_msg_with_functions([fn]) }

      allow(ctx).to receive(:messages).and_return(double("buffer", to_a: messages))

      middleware = described_class.new(inner_app, threshold: 3)
      env = build_env(context: ctx, provider: provider)

      middleware.call(env)

      expect(env[:metadata][:doom_loop_detected]).to be_nil
    end

    describe Brute::DoomLoopDetector do
      it "generates a warning message with repetition count" do
        detector = described_class.new(threshold: 3)
        msg = detector.warning_message(5)
        expect(msg).to include("Doom loop detected")
        expect(msg).to include("5 times")
      end
    end
  end
end
