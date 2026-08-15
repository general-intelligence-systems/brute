# frozen_string_literal: true

require_relative "../prompt_texts"

module Hermes
  module Middleware
    # IterationBudget — the loop cap + grace call (per-iteration).
    # Port of hermes-agent agent/iteration_budget.py + handle_max_iterations
    # (agent/chat_completion_helpers.py:2341). Subsumes Brute's MaxIterations
    # and Summarize.
    #
    # When env[:current_iteration] exceeds the cap, instead of dying on a tool
    # result the model gets ONE final tool-free grace call: the verbatim
    # MAX_ITERATIONS_SUMMARY_REQUEST is appended as a user message and the
    # inner stack runs once with env[:tools] emptied — the model summarizes
    # instead of calling more tools. Then should_exit.
    #
    # Per-agent: each pipeline instance has its own budget (subagents get
    # their own — hermes' delegation.max_iterations pattern).
    # execute_code iterations are refunded via #refund(env) — programmatic
    # tool calling must not eat the budget (wired when execute_code lands).
    class IterationBudget
      DEFAULT_MAX_ITERATIONS = 90

      def initialize(app, max_iterations: DEFAULT_MAX_ITERATIONS)
        @app = app
        @max_iterations = max_iterations
        @grace_used = false
      end

      def call(env)
        if (env[:current_iteration] || 1) > @max_iterations
          grace(env) unless @grace_used
          env[:should_exit] = { reason: "max_iterations" }
          return env
        end

        @app.call(env)
      end

      # Give back one iteration (execute_code turns).
      def refund(env)
        env[:current_iteration] -= 1 if (env[:current_iteration] || 1) > 1
      end

      private

      # The grace call: append the summary request as a user message and run
      # the inner stack once with tools disabled (env[:tool_free] — honored by
      # ToolPipeline and the terminal proc). The model summarizes instead of
      # calling more tools.
      def grace(env)
        @grace_used = true
        env[:messages] << Brute::Message.new(
          role: :user,
          content: Hermes::PromptTexts::MAX_ITERATIONS_SUMMARY_REQUEST,
        )
        env[:tool_free] = true
        @app.call(env)
      end
    end
  end
end
