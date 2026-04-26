# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    class UserQueue

      # Useful for testing...
      # App will keep looping till all inputs are drained.
      #
      def initialize(app, inputs: [])
        @app = app
        @inputs = inputs
      end

      def call(env)
        if @inputs.any?
          while inputs.any?
            inputs.shift.then do |input|
              @app.call(env)
            end
          end
        else
          @app.call
        end
      end
    end
  end
end

test do
  # not implemented
end
