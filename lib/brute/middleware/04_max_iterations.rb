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
          env[:callbacks].on_log("Max iterations reached (#{@max_iterations}). Stopping.")
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

  # Turn that loops exactly `loops` times via tool_results_queue, then stops.
  # The MaxIterations middleware wraps the inner app, counting each call.
  looping_turn = nil
  build_looping_turn = ->(max_iterations: 2, loops: 3) {
    call_count = 0
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::MaxIterations, max_iterations: max_iterations
      run ->(env) {
        call_count += 1
        if call_count < loops
          env[:tool_results_queue] = [Object.new]
        else
          env[:tool_results_queue] = nil
        end
        MockResponse.new(content: "ok")
      }
    end

    Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
  }

  it "passes through when under the limit" do
    turn = build_looping_turn.call(max_iterations: 10, loops: 2)
    turn.env[:should_exit].should.be.nil
  end

  it "sets should_exit when iterations exceed max" do
    turn = build_looping_turn.call(max_iterations: 2, loops: 5)
    turn.env[:should_exit][:reason].should == "max_iterations_reached"
    turn.env[:should_exit][:source].should == "MaxIterations"
  end

  it "tracks iteration count" do
    turn = build_looping_turn.call(max_iterations: 10, loops: 3)
    turn.env[:metadata][:iterations].should == 3
  end
end
