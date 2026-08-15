# frozen_string_literal: true

# Hermes::Middleware::EvolutionLog — after-turn middleware.
# See examples/hermes/MIDDLEWARE.md.
#
# Ports hermes-agent `picoclaw middleware/evolution_log.rb`:
# # records what the background review changed — the learning-loop audit trail.
#
# Scaffold: pass-through.
module Hermes
  module Middleware
    class EvolutionLog
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
