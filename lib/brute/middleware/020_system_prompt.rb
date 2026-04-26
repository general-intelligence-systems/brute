# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    class SystemPrompt
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end

test do
  # not implemented
end
