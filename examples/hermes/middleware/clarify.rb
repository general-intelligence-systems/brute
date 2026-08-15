# frozen_string_literal: true

# Hermes::Middleware::Clarify — per-turn middleware.
# See examples/hermes/MIDDLEWARE.md.
#
# Ports hermes-agent `tools/clarify_tool.py + clarify_gateway.py`:
# # installs the `clarify` tool (question, choices<=4, multi_select); blocks the turn thread on user
# input (timeout -> sentinel string); auto-refuses in subagent/cron contexts. Fills brute's
# unimplemented Middleware::Question (060).
#
# Scaffold: pass-through.
module Hermes
  module Middleware
    class Clarify
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
