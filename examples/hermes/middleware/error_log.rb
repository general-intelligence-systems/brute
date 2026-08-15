# frozen_string_literal: true

# Hermes::Middleware::ErrorLog — per-turn (around) middleware.
# See examples/hermes/MIDDLEWARE.md.
#
# Ports hermes-agent `hermes_logging.py`:
# # agent.log (INFO+) / errors.log (WARNING+) split. Wraps the turn so warnings and errors land in
# the right log file.
#
# Scaffold: pass-through.
module Hermes
  module Middleware
    class ErrorLog
      def initialize(app, **_opts)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
