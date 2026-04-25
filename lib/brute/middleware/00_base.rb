# frozen_string_literal: true

module Brute
  module Middleware
    # Base class for all middleware. Provides the standard Rack-style pattern:
    #
    #   def call(env)
    #     # pre-processing
    #     response = @app.call(env)
    #     # post-processing
    #     response
    #   end
    #
    # Subclasses MUST call @app.call(env) unless they are intentionally
    # short-circuiting (e.g., returning a cached response).
    #
    class Base
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end
