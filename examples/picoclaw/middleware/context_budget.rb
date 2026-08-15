# frozen_string_literal: true

require "fileutils"
require_relative "token_estimator"

# ContextBudget — picoclaw's proactive context enforcement (pkg/agent/
# context_budget.go + the SetupTurn proactive-compression path). The
# middleware runs the check once per turn (pre-loop); the module functions are
# shared with EmergencyCompression (the reactive, per-LLM-call path).
#
# Budget: estimate(messages incl. system) + tool defs + max_tokens >
# context_window. On overflow: FORCE-COMPRESS (drop the oldest ~50% of turns,
# never splitting tool-call sequences, appending the emergency note to the
# summary sidecar) then TRIM oldest whole turns until it fits — the active
# (last) turn and leading :system messages are never dropped.
#
# Defaults (picoclaw instance.go): max_tokens 0 => 8192; context_window 0 =>
# 4x max_tokens.
class ContextBudget
  class << self
    def resolve_max_tokens(value) = value.to_i.positive? ? value.to_i : 8192
    def resolve_window(value, max_tokens) = value.to_i.positive? ? value.to_i : 4 * max_tokens

    def estimate(messages, tool_defs)
      TokenEstimator.messages_tokens(messages) + TokenEstimator.tool_defs_tokens(tool_defs)
    end

    def over_budget?(messages, tool_defs:, max_tokens:, context_window:)
      estimate(messages, tool_defs) + max_tokens > context_window
    end

    # Turn boundaries = indices of :user messages (picoclaw parseTurnBoundaries).
    def turn_starts(messages)
      messages.each_index.select { |i| messages[i].role.to_sym == :user }
    end

    # forceCompression port: drop the oldest ~50% of turns; if a single turn
    # remains, keep only its last user message; append the emergency note to
    # the summary sidecar. Leading :system messages are preserved (upstream
    # compresses history before the system prompt is attached).
    def force_compress(messages, summary_path: nil)
      return 0 if messages.size <= 2

      head = messages.take_while { |m| m.role.to_sym == :system }.size
      rest = messages[head..] || []
      starts = turn_starts(rest)
      mid = starts.size >= 2 ? starts[starts.size / 2] : nil

      kept =
        if mid.nil? || mid <= 0
          last_user = rest.rindex { |m| m.role.to_sym == :user }
          last_user ? [rest[last_user]] : rest
        else
          rest[mid..]
        end

      dropped = messages.size - head - kept.size
      return 0 if dropped.zero?

      messages.replace(messages[0...head] + kept)

      if summary_path
        note = "[Emergency compression dropped #{dropped} oldest messages due to context limit]"
        existing = File.exist?(summary_path) ? File.read(summary_path) : ""
        merged = existing.empty? ? note : "#{existing}\n\n#{note}"
        FileUtils.mkdir_p(File.dirname(summary_path))
        File.write(summary_path, merged)
      end
      dropped
    end

    # trimHistoryToFitContextWindow port: drop oldest whole turns until the
    # estimate fits; the last turn is never dropped.
    def trim_to_fit(messages, tool_defs:, max_tokens:, context_window:)
      loop do
        break unless over_budget?(messages, tool_defs: tool_defs, max_tokens: max_tokens,
                                         context_window: context_window)

        head = messages.take_while { |m| m.role.to_sym == :system }.size
        rest = messages[head..] || []
        starts = turn_starts(rest)
        break if starts.size <= 1

        rest = rest[starts[1]..]
        messages.replace(messages[0...head] + rest)
      end
    end
  end

  def initialize(app, tool_defs: [], max_tokens: nil, context_window: nil, summary_path: nil)
    @app = app
    @tool_defs = tool_defs
    @max_tokens = self.class.resolve_max_tokens(max_tokens)
    @context_window = self.class.resolve_window(context_window, @max_tokens)
    @summary_path = summary_path
  end

  def call(env)
    if self.class.over_budget?(env[:messages], tool_defs: @tool_defs, max_tokens: @max_tokens,
                                               context_window: @context_window)
      self.class.force_compress(env[:messages], summary_path: @summary_path)
      self.class.trim_to_fit(env[:messages], tool_defs: @tool_defs, max_tokens: @max_tokens,
                                            context_window: @context_window)
    end
    @app.call(env)
  end
end
