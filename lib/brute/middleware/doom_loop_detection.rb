# frozen_string_literal: true

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
