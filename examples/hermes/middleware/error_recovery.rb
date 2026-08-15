# frozen_string_literal: true

# Hermes::Middleware::ErrorRecovery — per-iteration middleware.
# See examples/hermes/MIDDLEWARE.md.
#
# Ports hermes-agent `agent/error_classifier.py + run_agent.py:1942`:
# # classified retries (rate-limit/timeout/auth/billing), overflow -> compact -> retry (<=3),
# ephemeral empty-response scaffolding (flagged, never persisted), one-shot fallback model per
# turn.
#
# Scaffold: pass-through.
module Hermes
  module Middleware
    class ErrorRecovery
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
