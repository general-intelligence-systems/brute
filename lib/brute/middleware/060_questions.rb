# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    class Question < Brute::Middleware::Base
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)
      end
    end
  end
end

__END__

describe "brute/middleware/060_questions" do
  # not implemented
end
