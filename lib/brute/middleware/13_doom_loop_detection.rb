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
          env[:callbacks].on_log("Doom loop detected — #{reps} repetitions of the same tool call pattern. Stopping.")
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

  FakeFunc = Struct.new(:name, :arguments, keyword_init: true)

  def assistant_msg_with_functions(function_list)
    msg = LLM::Message.new(:assistant, "tool msg", {})
    msg.define_singleton_method(:functions) { function_list }
    msg
  end

  it "passes through when no doom loop" do
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::DoomLoopDetection, threshold: 3
      run ->(_env) { MockResponse.new(content: "ok") }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    turn.env[:metadata][:doom_loop_detected].should.be.nil
    turn.env[:should_exit].should.be.nil
  end

  it "detects consecutive identical tool calls and sets should_exit" do
    fn = FakeFunc.new(name: "fs_read", arguments: '{"path":"x.rb"}')
    messages = 4.times.map { assistant_msg_with_functions([fn]) }
    call_count = 0

    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::DoomLoopDetection, threshold: 3
      run ->(env) {
        call_count += 1
        # Inject doom-loop messages on first call, trigger a second call
        if call_count == 1
          env[:messages] = messages
          env[:tool_results_queue] = [Object.new]
        else
          env[:tool_results_queue] = nil
        end
        MockResponse.new(content: "loop check")
      }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    turn.env[:metadata][:doom_loop_detected].should.not.be.nil
    turn.env[:should_exit][:reason].should == "doom_loop_detected"
  end

  it "generates warning message with repetition count" do
    detector = Brute::Middleware::DoomLoopDetection::Detector.new(threshold: 3)
    msg = detector.warning_message(5)
    msg.should =~ /5 times/
  end
end
