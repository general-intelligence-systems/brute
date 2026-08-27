# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Guards against runaway tool loops by capping the number of iterations.
    #
    # When the limit is reached, injects a user message into the session
    # stating that maximum iterations have been reached. This causes
    # Loop::ToolResult to exit its loop naturally (last message is not :tool).
    #
    class MaxIterations < Brute::Middleware::Base

      DEFAULT_MAX_ITERATIONS = 100

      def initialize(app, max_iterations: DEFAULT_MAX_ITERATIONS)
        @app = app
        @max_iterations = max_iterations
      end

      def call(env)
        if max_iterations_reached?(env)
          env[:messages] << Brute::Message.new(
            role:    :user,
            content: "Maximum iterations reached.",
          )
        else
          @app.call(env)
        end
      end

      private

        def max_iterations_reached?(env)
          env[:current_iteration] > @max_iterations
        end
    end
  end
end

__END__

describe "brute/middleware/010_max_iterations" do
  require "brute/messages"

  it "lets the turn run under the max, then blocks the stack and injects a notice" do
    ran = []
    env = { messages: Brute.log.tap { |l| l.user("hi") }, current_iteration: 1 }

    Brute::Middleware::MaxIterations.new(->(e) { ran << e[:current_iteration] }).call(env)
    ran.should == [1]

    Brute::Middleware::MaxIterations.new(->(e) { ran << e[:current_iteration] }, max_iterations: 0).call(env)
    ran.should == [1]
    env[:messages].last.role.should == :user
    env[:messages].last.content.should =~ /Maximum iterations reached/
  end
end
