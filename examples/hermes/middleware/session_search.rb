# frozen_string_literal: true

# Hermes::Middleware::SessionSearch — per-turn middleware.
# See examples/hermes/MIDDLEWARE.md.
#
# Ports hermes-agent `hermes_state_search.py`:
# # FTS5 over the session store; installs the `session_search` tool (cross-session recall).
#
# Scaffold: pass-through.
module Hermes
  module Middleware
    class SessionSearch
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
