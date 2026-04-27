# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    class MaxIterations

      DEFAULT_MAX_ITERATIONS = 100

      def initialize(app, max_iterations: DEFAULT_MAX_ITERATIONS)
        @app = app
        @max_iterations = max_iterations
      end

      def call(env)
        if max_iterations_reached?(env)
          env[:should_exit] ||= {

            reason:  "max_iterations_reached",
            message: "Agent turn exceeded #{@max_iterations} iterations.",
            source:  "MaxIterations",
          }
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

test do
  it "can be added to a stack" do
    called = false
    inner = ->(env) { called = true }
    mw = Brute::Middleware::MaxIterations.new(inner)
    mw.call({ current_iteration: 1 })
    called.should.be.true
  end

  it "prevents execution after given max" do
    called = false
    inner = ->(env) { called = true }
    mw = Brute::Middleware::MaxIterations.new(inner, max_iterations: 0)
    env = { current_iteration: 1 }
    mw.call(env)
    called.should.be.false
  end
end
