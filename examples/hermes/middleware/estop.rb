# frozen_string_literal: true

# Hermes::Middleware::Estop — per-turn middleware.
# See examples/hermes/MIDDLEWARE.md.
#
# Ports hermes-agent `agent/estop.py`:
# # global pause sentinel (file-based, like `hermes pause`). Halts the turn when the sentinel
# exists; the cron driver checks the same sentinel before dispatch.
#
# Scaffold: pass-through.
module Hermes
  module Middleware
    class Estop
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
