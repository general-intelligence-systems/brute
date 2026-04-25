# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Tracks the number of pipeline calls (iterations) within an agent turn
    # and signals the loop to exit when the ceiling is reached.
    #
    # Runs PRE-call. Increments env[:metadata][:iterations] on every call.
    # When the count exceeds +max_iterations+, sets env[:should_exit] so the
    # agent loop terminates.
    #
    # First-writer-wins: does not overwrite env[:should_exit] if another
    # middleware already set it.
    #
    class MaxIterations < Base
      DEFAULT_MAX_ITERATIONS = 100

      def initialize(app, max_iterations: DEFAULT_MAX_ITERATIONS)
        super(app)
        @max_iterations = max_iterations
      end

      def call(env)
        env[:metadata][:iterations] ||= 0
        env[:metadata][:iterations] += 1

        if env[:metadata][:iterations] > @max_iterations
          env[:should_exit] ||= {
            reason:  "max_iterations_reached",
            message: "Agent turn exceeded #{@max_iterations} iterations. Stopping.",
            source:  "MaxIterations",
          }
        end

        @app.call(env)
      end
    end
  end
end

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  def build_env(**overrides)
    { provider: MockProvider.new, model: nil, input: "test prompt", tools: [],
      messages: [], stream: nil, params: {}, metadata: {}, callbacks: {},
      tool_results: nil, streaming: false, should_exit: nil, pending_functions: [] }.merge(overrides)
  end

  def make_middleware(app = nil, **kwargs)
    app ||= ->(_env) { MockResponse.new(content: "ok") }
    Brute::Middleware::MaxIterations.new(app, **kwargs)
  end

  it "passes through on the first call" do
    env = build_env
    make_middleware.call(env)
    env[:should_exit].should.be.nil
  end

  it "increments iteration count each call" do
    mw = make_middleware
    env = build_env
    3.times { mw.call(env) }
    env[:metadata][:iterations].should == 3
  end

  it "sets should_exit when iterations exceed max" do
    mw = make_middleware(max_iterations: 2)
    env = build_env
    3.times { mw.call(env) }
    env[:should_exit][:reason].should == "max_iterations_reached"
  end

  it "does not set should_exit at exactly max" do
    mw = make_middleware(max_iterations: 2)
    env = build_env
    2.times { mw.call(env) }
    env[:should_exit].should.be.nil
  end

  it "does not overwrite existing should_exit" do
    mw = make_middleware(max_iterations: 1)
    existing = { reason: "doom_loop_detected", message: "loop", source: "DoomLoop" }
    env = build_env(should_exit: existing)
    2.times { mw.call(env) }
    env[:should_exit][:reason].should == "doom_loop_detected"
  end

  it "uses default max of 100" do
    mw = make_middleware
    env = build_env
    100.times { mw.call(env) }
    env[:should_exit].should.be.nil
    mw.call(env)
    env[:should_exit][:reason].should == "max_iterations_reached"
  end

  it "sets source to MaxIterations" do
    mw = make_middleware(max_iterations: 1)
    env = build_env
    2.times { mw.call(env) }
    env[:should_exit][:source].should == "MaxIterations"
  end
end
