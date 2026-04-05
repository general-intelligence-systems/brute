# frozen_string_literal: true

module Brute
  module Middleware
    # Saves the conversation to disk after each LLM call.
    #
    # Runs POST-call: delegates to Session#save. Failures are non-fatal —
    # a broken session save should never crash the agent loop.
    #
    class SessionPersistence < Base
      def initialize(app, session:)
        super(app)
        @session = session
      end

      def call(env)
        response = @app.call(env)

        begin
          @session.save(env[:context])
        rescue => e
          warn "[brute] Session save failed: #{e.message}"
        end

        response
      end
    end
  end
end
