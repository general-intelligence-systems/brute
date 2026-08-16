# frozen_string_literal: true

module Hermes
  module Middleware
    # Estop — the global pause sentinel (per-turn, first in the chain).
    # Port of hermes-agent agent/estop.py: when the sentinel file exists the
    # turn halts immediately (and the tick driver checks the same file before
    # running any due work). Pause = create the file; resume = delete it.
    class Estop
      def initialize(app, sentinel: File.join(Dir.pwd, ".estop"))
        @app = app
        @sentinel = sentinel
      end

      def call(env)
        if File.exist?(@sentinel)
          env[:should_exit] = { reason: "estop" }
          env[:events] << {
            type: :status,
            data: { message: "⏸ Paused — estop sentinel present (#{@sentinel}). Remove it to resume." },
          }
          return env
        end

        @app.call(env)
      end
    end
  end
end
