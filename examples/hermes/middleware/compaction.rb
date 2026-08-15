# frozen_string_literal: true

require_relative "../compactor"

module Hermes
  module Middleware
    # Compaction — the pre-API-call context gate (per-iteration).
    # Port of hermes-agent's preflight/pressure/overflow compaction paths.
    #
    # Before each LLM call: if the context estimate (provider-reported usage
    # from TokenUsage when present, else chars/4) is at/over the threshold,
    # compress env[:messages] via the injected Compactor. After-effects:
    #   - the todo list is re-injected ("preserved across context compression")
    #   - env[:invalidate_system_prompt] = true (PromptTiers rebuilds — its
    #     volatile band picks up live memory/skills)
    #   - a :compaction status event is emitted
    #
    # Backstop: at most max_attempts consecutive compactions without the
    # context dropping below threshold (hermes' ineffective-attempt guard).
    class Compaction
      def initialize(app, compactor:, max_attempts: 3)
        @app = app
        @compactor = compactor
        @max_attempts = max_attempts
        @attempts = 0
      end

      def call(env)
        maybe_compact(env)
        @app.call(env)
      end

      private

      def maybe_compact(env)
        return if @attempts >= @max_attempts

        tokens = env.dig(:usage, :input)
        return unless @compactor.should_compress?(env[:messages], tokens: tokens)

        new_messages = @compactor.compress(env[:messages])
        return unless new_messages

        env[:messages] = new_messages.extend(Brute::Messages)

        # Re-inject the active todo list (hermes: "preserved across context
        # compression") — appended as a user message only when the tail is
        # assistant, so role alternation stays valid.
        injection = env[:todo_store]&.format_for_injection
        if injection && env[:messages].last&.role == :assistant
          env[:messages] << Brute::Message.new(role: :user, content: injection)
        end

        env[:invalidate_system_prompt] = true
        env[:events] << { type: :compaction, data: { messages_after: new_messages.size } }

        # Rearm only when the compaction actually dropped us below threshold.
        @attempts = @compactor.should_compress?(env[:messages]) ? @attempts + 1 : 0
      end
    end
  end
end
