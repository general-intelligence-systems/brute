# frozen_string_literal: true

require "bundler/setup"
require "brute"

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

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  def build_env(**overrides)
    { provider: MockProvider.new, model: nil, input: "test prompt", tools: [],
      messages: [], stream: nil, params: {}, metadata: {}, callbacks: {},
      tool_results: nil, streaming: false, should_exit: nil, pending_functions: [] }.merge(overrides)
  end

  def make_compactor(should: false, result: nil)
    Object.new.tap do |c|
      c.define_singleton_method(:should_compact?) { |_msgs, **_| should }
      c.define_singleton_method(:compact) { |_msgs| result }
    end
  end

  it "passes the response through when compaction is not needed" do
    response = MockResponse.new(content: "compaction response")
    compactor = make_compactor(should: false)
    middleware = Brute::Middleware::CompactionCheck.new(->(_env) { response }, compactor: compactor, system_prompt: "sys")
    result = middleware.call(build_env)
    result.should == response
  end

  it "does not set compaction metadata when not needed" do
    compactor = make_compactor(should: false)
    middleware = Brute::Middleware::CompactionCheck.new(->(_env) { MockResponse.new }, compactor: compactor, system_prompt: "sys")
    env = build_env
    middleware.call(env)
    env[:metadata][:compaction].should.be.nil
  end

  it "replaces messages with summary when compaction triggers" do
    compactor = make_compactor(should: true, result: ["Summary of conversation", []])
    middleware = Brute::Middleware::CompactionCheck.new(->(_env) { MockResponse.new }, compactor: compactor, system_prompt: "sys")
    env = build_env(messages: [LLM::Message.new(:user, "hello"), LLM::Message.new(:assistant, "hi"), LLM::Message.new(:user, "how")])
    middleware.call(env)
    env[:metadata][:compaction][:messages_before].should == 3
  end

  it "creates two messages after compaction" do
    compactor = make_compactor(should: true, result: ["Summary", []])
    middleware = Brute::Middleware::CompactionCheck.new(->(_env) { MockResponse.new }, compactor: compactor, system_prompt: "sys")
    env = build_env(messages: [LLM::Message.new(:user, "hello")])
    middleware.call(env)
    env[:messages].size.should == 2
  end

  it "handles compactor returning nil gracefully" do
    compactor = make_compactor(should: true, result: nil)
    middleware = Brute::Middleware::CompactionCheck.new(->(_env) { MockResponse.new }, compactor: compactor, system_prompt: "sys")
    env = build_env(messages: [LLM::Message.new(:user, "hello")])
    middleware.call(env)
    env[:metadata][:compaction].should.be.nil
  end
end
