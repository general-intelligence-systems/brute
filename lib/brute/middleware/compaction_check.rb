# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Middleware
    # Checks context size after each LLM call and triggers compaction
    # when thresholds are exceeded.
    #
    # Runs POST-call: inspects message count and token usage. If compaction
    # is needed, summarizes older messages and replaces env[:messages] with
    # the summary so the next LLM call starts with a compact history.
    #
    class CompactionCheck < Base
      def initialize(app, compactor:, system_prompt:)
        super(app)
        @compactor = compactor
        @system_prompt = system_prompt
      end

      def call(env)
        response = @app.call(env)

        messages = env[:messages]
        usage = env[:metadata].dig(:tokens, :last_call)

        if @compactor.should_compact?(messages, usage: usage)
          result = @compactor.compact(messages)
          if result
            summary_text, _recent = result
            env[:metadata][:compaction] = {
              messages_before: messages.size,
              timestamp: Time.now.iso8601,
            }
            # Replace the message history with the summary
            env[:messages] = [
              LLM::Message.new(:system, @system_prompt),
              LLM::Message.new(:user, "[Previous conversation summary]\n\n#{summary_text}"),
            ]
          end
        end

        response
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Middleware::CompactionCheck do
    let(:response) { MockResponse.new(content: "compaction response") }
    let(:inner_app) { ->(_env) { response } }
    let(:compactor) { double("compactor") }
    let(:system_prompt) { "You are a helpful assistant." }
    let(:middleware) do
      described_class.new(inner_app, compactor: compactor, system_prompt: system_prompt)
    end

    it "passes the response through when compaction is not needed" do
      allow(compactor).to receive(:should_compact?).and_return(false)
      env = build_env

      result = middleware.call(env)

      expect(result).to eq(response)
      expect(env[:metadata][:compaction]).to be_nil
    end

    it "does not replace messages when compaction is not triggered" do
      allow(compactor).to receive(:should_compact?).and_return(false)
      original_messages = [LLM::Message.new(:user, "hello")]
      env = build_env(messages: original_messages)

      middleware.call(env)

      expect(env[:messages]).to equal(original_messages)
    end

    it "replaces messages with summary when compaction triggers" do
      allow(compactor).to receive(:should_compact?).and_return(true)
      allow(compactor).to receive(:compact).and_return(["Summary of conversation", []])

      original_messages = [
        LLM::Message.new(:user, "hello"),
        LLM::Message.new(:assistant, "hi there"),
        LLM::Message.new(:user, "how are you"),
      ]
      env = build_env(messages: original_messages)
      middleware.call(env)

      expect(env[:metadata][:compaction]).to include(:messages_before, :timestamp)
      expect(env[:metadata][:compaction][:messages_before]).to eq(3)
      expect(env[:messages].size).to eq(2)
      expect(env[:messages][0].role.to_s).to eq("system")
      expect(env[:messages][1].content).to include("Summary of conversation")
    end

    it "handles compactor returning nil gracefully" do
      allow(compactor).to receive(:should_compact?).and_return(true)
      allow(compactor).to receive(:compact).and_return(nil)

      original_messages = [LLM::Message.new(:user, "hello")]
      env = build_env(messages: original_messages)

      middleware.call(env)

      expect(env[:messages]).to equal(original_messages)
      expect(env[:metadata][:compaction]).to be_nil
    end

    it "works regardless of streaming mode" do
      allow(compactor).to receive(:should_compact?).and_return(true)
      allow(compactor).to receive(:compact).and_return(["Summary", []])

      env = build_env(
        messages: [LLM::Message.new(:user, "hello")],
        streaming: true,
        stream: double("AgentStream"),
      )
      middleware.call(env)

      # Compaction works the same — no stream forwarding needed
      expect(env[:messages].size).to eq(2)
      expect(env[:metadata][:compaction]).not_to be_nil
    end
  end
end
