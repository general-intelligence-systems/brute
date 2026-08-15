# frozen_string_literal: true

module Hermes
  module Middleware
    # TokenUsage — per-call token accounting (per-iteration).
    # Port of hermes-agent agent/context_breakdown.py: estimation is
    # deliberately rough (chars/4 — no tokenizer dependency); real
    # provider-reported usage wins when the transport reports it.
    #
    # After each LLM call: env[:usage] gets the last call's
    # {input, output, total}; env[:metadata][:usage] accumulates per-turn
    # totals. Feeds Compaction's threshold checks and /usage.
    class TokenUsage
      CHARS_PER_TOKEN = 4

      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)

        usage = real_usage(env) || estimate(env)
        env[:usage] = usage
        acc = (env[:metadata] ||= {})[:usage] ||= { input: 0, output: 0, total: 0, calls: 0 }
        acc[:input] += usage[:input]
        acc[:output] += usage[:output]
        acc[:total] += usage[:total]
        acc[:calls] += 1

        env
      end

      # Rough estimate: chars/4 over message contents (hermes _chars_to_tokens).
      def self.estimate_tokens(text)
        (text.to_s.length + 3) / CHARS_PER_TOKEN
      end

      def self.estimate_messages(messages)
        messages.sum { |m| estimate_tokens(m.content.to_s) }
      end

      private

      # The transport may stamp provider-reported usage on the env
      # (e.g. env[:response_usage] = {input:, output:}).
      def real_usage(env)
        raw = env[:response_usage]
        return nil unless raw.is_a?(Hash) && (raw[:input] || raw[:output])

        input = raw[:input].to_i
        output = raw[:output].to_i
        { input: input, output: output, total: input + output, source: :provider }
      end

      def estimate(env)
        # Estimate from the last exchange: new messages since the prior call.
        msgs = env[:messages] || []
        input = self.class.estimate_messages(msgs)
        last = msgs.select { |m| m.role == :assistant }.last
        output = last ? self.class.estimate_tokens(last.content.to_s) : 0
        { input: input, output: output, total: input + output, source: :estimate }
      end
    end
  end
end
