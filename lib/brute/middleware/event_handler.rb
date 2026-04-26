# frozen_string_literal: true

require 'bundler/setup'
require 'brute'

module Brute
  module Middleware
    class EventHandler
      def initialize(app, handler_class:, **opts)
        @app = app
        @handler_class = handler_class
        @opts = opts
      end

      def call(env)
        env[:events] = @handler_class.new(env[:events], **opts)
        @app.call(env)
      end
    end
  end
end

test do
  # not implemented
end
