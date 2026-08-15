# frozen_string_literal: true

# Hermes::Middleware::ProcessRegistry — per-turn middleware.
# See examples/hermes/MIDDLEWARE.md.
#
# Ports hermes-agent `tools/process_registry.py`:
# # installs the `process` tool (list|poll|log|wait|kill|write|submit|close); terminal
# background=true + notify_on_complete -> completion queue; flags stripped in finite sessions.
#
# Scaffold: pass-through.
module Hermes
  module Middleware
    class ProcessRegistry
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
