# frozen_string_literal: true

require_relative "../prompt_texts"

module Hermes
  module Middleware
    # Steering — mid-loop user steering, role-alternation-safe (per-iteration).
    # Port of hermes-agent conversation_loop.py:1783 (pre-API steer drain) +
    # :242 (_apply_active_turn_redirect).
    #
    # The driver enqueues while the model works:
    #   Hermes::Steering.steer("focus on the tests")
    #   Hermes::Steering.redirect("actually, use postgres")
    #
    # Steer: drained BEFORE each API call and appended to the LAST :tool
    # message, wrapped in the verbatim marker ([OUT-OF-BAND USER MESSAGE — …]).
    # If no tool message exists yet, it stays pending — never a new user
    # message mid-loop.
    #
    # Redirect (the harder case — a correction that ends the current line):
    # appended as a real user message carrying the interruption checkpoint
    # ("[This response was interrupted by a user correction.]" + the visible
    # pre-interruption text). Valid alternation: the mid-loop tail is :tool,
    # so a :user message follows legally.
    class Steering
      INTERRUPT_SCAFFOLD_MARKER = "[This response was interrupted by a user correction.]"

      def initialize(app)
        @app = app
      end

      def call(env)
        drain_redirect(env)
        drain_steer(env)
        @app.call(env)
      end

      private

      def drain_steer(env)
        return if Hermes::Steering.pending.empty?

        idx = env[:messages].rindex { |m| m.role == :tool }
        return unless idx # no tool message yet — steer stays pending for the next batch

        text = Hermes::Steering.pending.join("\n")
        Hermes::Steering.pending.clear

        old = env[:messages][idx]
        env[:messages][idx] = Brute::Message.new(
          role: :tool,
          content: old.content.to_s + format_marker(text),
          tool_call_id: old.tool_call_id,
        )
        env[:events] << { type: :steer, data: { text: text } }
      end

      def drain_redirect(env)
        return if Hermes::Steering.redirects.empty?

        text = Hermes::Steering.redirects.join("\n")
        Hermes::Steering.redirects.clear

        visible = env[:messages].reverse.find { |m| m.role == :assistant }
                    &.content.to_s.strip
        checkpoint = [INTERRUPT_SCAFFOLD_MARKER]
        checkpoint += ["Visible response before the interruption:", visible] unless visible.to_s.empty?
        correction = "[Context from the interrupted assistant response]\n" \
                     "#{checkpoint.join("\n\n")}\n\n#{text}"

        env[:messages] << Brute::Message.new(role: :user, content: correction)
        env[:events] << { type: :redirect, data: { text: text } }
      end

      def format_marker(text)
        "\n\n#{Hermes::PromptTexts::STEER_MARKER_OPEN}\n#{text}\n#{Hermes::PromptTexts::STEER_MARKER_CLOSE}"
      end
    end
  end

  # Thread-local steering queues (the driver enqueues; the middleware drains).
  module Steering
    module_function

    def pending
      Thread.current[:hermes_steer_queue] ||= []
    end

    def redirects
      Thread.current[:hermes_redirect_queue] ||= []
    end

    def steer(text)
      pending << text
    end

    def redirect(text)
      redirects << text
    end

    def clear!
      pending.clear
      redirects.clear
    end
  end
end
