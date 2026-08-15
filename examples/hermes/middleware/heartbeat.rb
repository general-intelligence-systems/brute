# frozen_string_literal: true

# Hermes::Middleware::Heartbeat — per-turn middleware.
# See examples/hermes/MIDDLEWARE.md.
#
# Ports hermes-agent `hermes_cli/heartbeat.py`:
# # user-owned recurring instruction (`/heartbeat every <interval> <prompt>`); fires only when the
# session is idle; 'do not invent work' frame; missed ticks coalesce.
#
# Scaffold: pass-through.
module Hermes
  module Middleware
    class Heartbeat
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
