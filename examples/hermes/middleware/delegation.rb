# frozen_string_literal: true

# Hermes::Middleware::Delegation — per-turn middleware.
# See examples/hermes/MIDDLEWARE.md.
#
# Ports hermes-agent `tools/delegate_tool.py + async_delegation.py`:
# # installs `delegate_task` (single/batch, leaf|orchestrator, action list|steer|stop); background
# children via threads + shared completion queue + durable ledger; summary caps with spill files;
# depth/concurrency caps.
#
# Scaffold: pass-through.
module Hermes
  module Middleware
    class Delegation
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
