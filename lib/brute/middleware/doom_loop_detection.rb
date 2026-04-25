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
        @detector = Detector.new(threshold: threshold)
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

      # Detects when the agent is stuck in a repeating pattern of tool calls.
      #
      # Two types of loops are detected:
      #   1. Consecutive identical calls: [A, A, A] — same tool + same args
      #   2. Repeating sequences: [A,B,C, A,B,C, A,B,C] — a pattern cycling
      #
      # When detected, a warning is injected into the context so the LLM
      # can course-correct.
      class Detector
        DEFAULT_THRESHOLD = 3

        attr_reader :threshold

        def initialize(threshold: DEFAULT_THRESHOLD)
          @threshold = threshold
        end

        # Extracts tool call signatures from the context's message buffer and
        # checks for repeating patterns at the tail.
        #
        # Returns the repetition count if a loop is found, nil otherwise.
        def detect(messages)
          signatures = extract_signatures(messages)
          return nil if signatures.size < @threshold

          check_repeating_pattern(signatures)
        end

        # Build a human-readable warning message for the agent.
        def warning_message(repetitions)
          <<~MSG
            SYSTEM NOTICE: Doom loop detected — the same tool call pattern has repeated #{repetitions} times.
            You are stuck in a loop and not making progress. Stop and try a fundamentally different approach:
            - Re-read the file to check your changes actually applied
            - Try a different tool or strategy
            - Break the problem into smaller steps
            - If a command keeps failing, investigate why before retrying
          MSG
        end

        private

        # Extract [tool_name, arguments_json] pairs from assistant messages.
        def extract_signatures(messages)
          messages
            .select { |m| m.respond_to?(:functions) && m.assistant? }
            .flat_map { |m| m.functions.map { |f| [f.name.to_s, f.arguments.to_s] } }
        end

        # Check for repeating patterns of any length at the tail of the sequence.
        # Returns the repetition count, or nil.
        def check_repeating_pattern(sequence)
          max_pattern_len = sequence.size / @threshold

          (1..max_pattern_len).each do |pattern_len|
            count = count_tail_repetitions(sequence, pattern_len)
            return count if count >= @threshold
          end

          nil
        end

        # Count how many times a pattern of `length` repeats at the end of the sequence.
        def count_tail_repetitions(sequence, length)
          return 0 if sequence.size < length

          pattern = sequence.last(length)
          count = 1
          pos = sequence.size - length

          while pos >= length
            candidate = sequence[(pos - length)...pos]
            break unless candidate == pattern
            count += 1
            pos -= length
          end

          count
        end
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
    detector = Brute::Middleware::DoomLoopDetection::Detector.new(threshold: 3)
    msg = detector.warning_message(5)
    msg.should =~ /5 times/
  end
end
