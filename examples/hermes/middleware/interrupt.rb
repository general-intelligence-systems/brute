# frozen_string_literal: true

module Hermes
  module Middleware
    # Interrupt — per-iteration interrupt check (inside the loop).
    # Port of hermes-agent tools/interrupt.py + conversation_loop.py:1724.
    #
    # Thread-scoped (hermes: interrupting one session must not kill tools of
    # another): the driver or a watchdog calls Hermes::Interrupt.request! and
    # the next iteration exits with env[:should_exit] = { reason: "interrupted" }.
    # Tool waits poll Hermes::Interrupt.requested? for mid-tool aborts.
    class Interrupt
      def initialize(app)
        @app = app
      end

      def call(env)
        if Hermes::Interrupt.requested?
          env[:should_exit] = { reason: "interrupted" }
          env[:events] << { type: :status, data: { message: "⚡ Breaking out of tool loop due to interrupt..." } }
          return env
        end

        @app.call(env)
      end
    end
  end

  # Thread-scoped interrupt flag (hermes: a set of interrupted thread idents).
  module Interrupt
    module_function

    def request!
      Thread.current[:hermes_interrupt] = true
    end

    def clear!
      Thread.current[:hermes_interrupt] = false
    end

    def requested?
      Thread.current[:hermes_interrupt] == true
    end
  end
end
