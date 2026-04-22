# frozen_string_literal: true

require "bundler/setup"
require "brute"

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

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  def build_env(**overrides)
    { provider: MockProvider.new, model: nil, input: "test prompt", tools: [],
      messages: [], stream: nil, params: {}, metadata: {}, callbacks: {},
      tool_results: nil, streaming: false, should_exit: nil, pending_functions: [] }.merge(overrides)
  end

  FakeFunc = Struct.new(:name, :arguments, keyword_init: true)

  def assistant_msg_with_functions(function_list)
    msg = LLM::Message.new(:assistant, "tool msg", {})
    msg.define_singleton_method(:functions) { function_list }
    msg
  end

  it "passes through when no doom loop is detected" do
    inner_app = ->(_env) { MockResponse.new(content: "loop check") }
    middleware = Brute::Middleware::DoomLoopDetection.new(inner_app, threshold: 3)
    env = build_env
    middleware.call(env)
    env[:metadata][:doom_loop_detected].should.be.nil
  end

  it "detects consecutive identical tool calls" do
    inner_app = ->(_env) { MockResponse.new(content: "loop check") }
    fn = FakeFunc.new(name: "fs_read", arguments: '{"path":"x.rb"}')
    messages = 4.times.map { assistant_msg_with_functions([fn]) }
    middleware = Brute::Middleware::DoomLoopDetection.new(inner_app, threshold: 3)
    env = build_env(messages: messages)
    middleware.call(env)
    env[:metadata][:doom_loop_detected].should.not.be.nil
  end

  it "does not trigger below the threshold" do
    inner_app = ->(_env) { MockResponse.new(content: "loop check") }
    fn = FakeFunc.new(name: "fs_read", arguments: '{"path":"x.rb"}')
    messages = 2.times.map { assistant_msg_with_functions([fn]) }
    middleware = Brute::Middleware::DoomLoopDetection.new(inner_app, threshold: 3)
    env = build_env(messages: messages)
    middleware.call(env)
    env[:metadata][:doom_loop_detected].should.be.nil
  end

  it "sets should_exit reason when doom loop detected" do
    inner_app = ->(_env) { MockResponse.new(content: "loop check") }
    fn = FakeFunc.new(name: "fs_read", arguments: '{"path":"x.rb"}')
    messages = 4.times.map { assistant_msg_with_functions([fn]) }
    middleware = Brute::Middleware::DoomLoopDetection.new(inner_app, threshold: 3)
    env = build_env(messages: messages)
    middleware.call(env)
    env[:should_exit][:reason].should == "doom_loop_detected"
  end

  it "does not set should_exit when no loop detected" do
    inner_app = ->(_env) { MockResponse.new(content: "loop check") }
    middleware = Brute::Middleware::DoomLoopDetection.new(inner_app, threshold: 3)
    env = build_env
    middleware.call(env)
    env[:should_exit].should.be.nil
  end

  it "does not overwrite should_exit if already set" do
    inner_app = ->(_env) { MockResponse.new(content: "loop check") }
    fn = FakeFunc.new(name: "fs_read", arguments: '{"path":"x.rb"}')
    messages = 4.times.map { assistant_msg_with_functions([fn]) }
    middleware = Brute::Middleware::DoomLoopDetection.new(inner_app, threshold: 3)
    existing = { reason: "other", message: "earlier", source: "Other" }
    env = build_env(messages: messages, should_exit: existing)
    middleware.call(env)
    env[:should_exit][:reason].should == "other"
  end

  it "appends a warning message when loop detected" do
    inner_app = ->(_env) { MockResponse.new(content: "loop check") }
    fn = FakeFunc.new(name: "fs_read", arguments: '{"path":"x.rb"}')
    messages = 4.times.map { assistant_msg_with_functions([fn]) }
    middleware = Brute::Middleware::DoomLoopDetection.new(inner_app, threshold: 3)
    env = build_env(messages: messages)
    original_count = env[:messages].size
    middleware.call(env)
    env[:messages].size.should == original_count + 1
  end

  it "generates warning message with repetition count" do
    detector = Brute::Loop::DoomLoopDetector.new(threshold: 3)
    msg = detector.warning_message(5)
    msg.should =~ /5 times/
  end
end
