# frozen_string_literal: true

# Hermes::Middleware::MemoryProviders — per-turn middleware.
# See examples/hermes/MIDDLEWARE.md.
#
# Ports hermes-agent `agent/memory_manager.py`:
# # external memory provider seam: prefetch(query) at turn start, sync_turn(turn) at turn end
# (honcho et al.); skipped in cron/subagent contexts.
#
# Scaffold: pass-through.
module Hermes
  module Middleware
    class MemoryProviders
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
