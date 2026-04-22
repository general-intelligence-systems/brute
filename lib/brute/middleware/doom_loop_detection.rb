# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Middleware
    # Detects when the agent is stuck repeating tool call patterns and injects
    # a corrective warning into the message history before the next LLM call.
    #
    # Runs PRE-call: inspects the conversation history for repeating tool call
    # patterns. If detected, appends a warning message so the LLM sees it as
    # input alongside the normal tool results.
    #
    class DoomLoopDetection < Base
      def initialize(app, threshold: 3)
        super(app)
        @detector = Brute::Loop::DoomLoopDetector.new(threshold: threshold)
      end

      def call(env)
        messages = env[:messages]

        if (reps = @detector.detect(messages))
          warning = @detector.warning_message(reps)
          # Inject the warning as a user message so the LLM sees it
          env[:messages] << LLM::Message.new(:user, warning)
          env[:metadata][:doom_loop_detected] = reps

          # Signal the agent loop to exit after this LLM call completes.
          # First-writer-wins: don't overwrite if another middleware already set it.
          env[:should_exit] ||= {
            reason:  "doom_loop_detected",
            message: "Agent is stuck repeating the same tool calls (#{reps} repetitions).",
            source:  "DoomLoopDetection",
          }
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
      fn = fake_function(name: "fs_read", arguments: '{"path":"x.rb"}')
      messages = 4.times.map { assistant_msg_with_functions([fn]) }

      middleware = described_class.new(inner_app, threshold: 3)
      env = build_env(messages: messages)

      middleware.call(env)

      expect(env[:metadata][:doom_loop_detected]).not_to be_nil
    end

    it "detects repeating sequences [A,B,A,B,A,B]" do
      fn_a = fake_function(name: "fs_read", arguments: '{"path":"a.rb"}')
      fn_b = fake_function(name: "shell", arguments: '{"cmd":"ls"}')
      messages = 3.times.flat_map do
        [assistant_msg_with_functions([fn_a]), assistant_msg_with_functions([fn_b])]
      end

      middleware = described_class.new(inner_app, threshold: 3)
      env = build_env(messages: messages)

      middleware.call(env)

      expect(env[:metadata][:doom_loop_detected]).not_to be_nil
    end

    it "does not trigger below the threshold" do
      fn = fake_function(name: "fs_read", arguments: '{"path":"x.rb"}')
      messages = 2.times.map { assistant_msg_with_functions([fn]) }

      middleware = described_class.new(inner_app, threshold: 3)
      env = build_env(messages: messages)

      middleware.call(env)

      expect(env[:metadata][:doom_loop_detected]).to be_nil
    end

    # -- should_exit signal --

    it "sets env[:should_exit] when a doom loop is detected" do
      fn = fake_function(name: "fs_read", arguments: '{"path":"x.rb"}')
      messages = 4.times.map { assistant_msg_with_functions([fn]) }

      middleware = described_class.new(inner_app, threshold: 3)
      env = build_env(messages: messages)

      middleware.call(env)

      expect(env[:should_exit]).to be_a(Hash)
      expect(env[:should_exit][:reason]).to eq("doom_loop_detected")
      expect(env[:should_exit][:source]).to eq("DoomLoopDetection")
      expect(env[:should_exit][:message]).to include("repetitions")
    end

    it "does not set env[:should_exit] when no loop is detected" do
      middleware = described_class.new(inner_app, threshold: 3)
      env = build_env

      middleware.call(env)

      expect(env[:should_exit]).to be_nil
    end

    it "does not overwrite env[:should_exit] if already set (first-writer-wins)" do
      fn = fake_function(name: "fs_read", arguments: '{"path":"x.rb"}')
      messages = 4.times.map { assistant_msg_with_functions([fn]) }

      middleware = described_class.new(inner_app, threshold: 3)
      existing_exit = { reason: "other", message: "earlier middleware", source: "Other" }
      env = build_env(messages: messages, should_exit: existing_exit)

      middleware.call(env)

      # should_exit still has the original value
      expect(env[:should_exit][:reason]).to eq("other")
      expect(env[:should_exit][:source]).to eq("Other")
    end

    it "appends a warning message to env[:messages] when loop is detected" do
      fn = fake_function(name: "fs_read", arguments: '{"path":"x.rb"}')
      messages = 4.times.map { assistant_msg_with_functions([fn]) }

      middleware = described_class.new(inner_app, threshold: 3)
      env = build_env(messages: messages)
      original_count = env[:messages].size

      middleware.call(env)

      expect(env[:messages].size).to eq(original_count + 1)
      expect(env[:messages].last.role.to_s).to eq("user")
    end

    describe Brute::Loop::DoomLoopDetector do
      it "generates a warning message with repetition count" do
        detector = described_class.new(threshold: 3)
        msg = detector.warning_message(5)
        expect(msg).to include("Doom loop detected")
        expect(msg).to include("5 times")
      end
    end
  end
end
