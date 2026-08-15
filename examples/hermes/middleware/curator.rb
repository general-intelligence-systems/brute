# frozen_string_literal: true

# Hermes::Middleware::Curator — per-turn (timer check) middleware.
# See examples/hermes/MIDDLEWARE.md.
#
# Ports hermes-agent `agent/curator.py`:
# # skill lifecycle gardener: usage-based stale->archive transitions for created_by: agent skills
# only; never deletes; tar.gz backups; pinned exempt.
#
# Scaffold: pass-through.
module Hermes
  module Middleware
    class Curator
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
