# frozen_string_literal: true

# Hermes::Middleware::ContextEngine — per-turn middleware.
# See examples/hermes/MIDDLEWARE.md.
#
# Ports hermes-agent `agent/context_engine.py`:
# # pluggable context-engine seam (plugin-selected context assembly). PromptTiers is the built-in
# engine; this is the slot where external engines attach.
#
# Scaffold: pass-through.
module Hermes
  module Middleware
    class ContextEngine
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
