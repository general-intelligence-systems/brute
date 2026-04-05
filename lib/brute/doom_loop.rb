# frozen_string_literal: true

module Brute
  # Detects when the agent is stuck in a repeating pattern of tool calls.
  #
  # Two types of loops are detected:
  #   1. Consecutive identical calls: [A, A, A] — same tool + same args
  #   2. Repeating sequences: [A,B,C, A,B,C, A,B,C] — a pattern cycling
  #
  # When detected, a warning is injected into the context so the LLM
  # can course-correct.
  class DoomLoopDetector
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
