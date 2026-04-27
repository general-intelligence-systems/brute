# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Guards against runaway tool loops by capping the number of iterations.
    #
    # When the limit is reached, injects a user message into the session
    # stating that maximum iterations have been reached. This causes
    # ToolResultLoop to exit its loop naturally (last message is not :tool).
    #
    class MaxIterations

      DEFAULT_MAX_ITERATIONS = 100

      def initialize(app, max_iterations: DEFAULT_MAX_ITERATIONS)
        @app = app
        @max_iterations = max_iterations
      end

      def call(env)
        if max_iterations_reached?(env)
          env[:messages] << RubyLLM::Message.new(
            role: :user,
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

test do
  require "brute/session"

  it "can be added to a stack" do
    called = false
    inner = ->(env) { called = true }
    mw = Brute::Middleware::MaxIterations.new(inner)
    mw.call({ current_iteration: 1, messages: Brute::Session.new })
    called.should.be.true
  end

  it "prevents execution after given max" do
    called = false
    inner = ->(env) { called = true }
    mw = Brute::Middleware::MaxIterations.new(inner, max_iterations: 0)
    env = { current_iteration: 1, messages: Brute::Session.new }
    mw.call(env)
    called.should.be.false
  end

  it "injects a user message when max is hit" do
    inner = ->(env) { }
    mw = Brute::Middleware::MaxIterations.new(inner, max_iterations: 0)
    session = Brute::Session.new
    session.user("hi")
    env = { current_iteration: 1, messages: session }
    mw.call(env)
    env[:messages].last.role.should == :user
    env[:messages].last.content.should =~ /Maximum iterations reached/
  end
end
