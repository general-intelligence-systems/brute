# frozen_string_literal: true

# Hermes::Middleware::UsageAudit — per-iteration middleware.
# See examples/hermes/MIDDLEWARE.md.
#
# Ports hermes-agent `cron/scheduler.py:4624`:
# # appends per-call usage audit records (the usage_audit.jsonl analogue).
#
# Scaffold: pass-through.
module Hermes
  module Middleware
    class UsageAudit
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
