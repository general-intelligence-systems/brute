# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # Stage 3 — refine at turn boundaries.
    #
    # After each LLM+tools pass, hands the trajectory to the Refiner: a
    # pending `refine.run` request from the kernel runs immediately;
    # otherwise every `turn_interval` assistant turns the auto-review gate
    # decides whether the trajectory holds lessons worth persisting in the
    # continual harness. This is the analogue of prime-agent's auto-refine
    # scheduler (agent-session.ts _maybeAutoRefine), which runs refinement
    # when a turn ends.
    #
    # Place inside the turn loop, below MaxIterations:
    #
    #   .use(Brute::Middleware::MaxIterations)
    #   .use(PrimeAgent::Middleware::AutoRefine, refiner: refiner)
    #   .use(Brute::Middleware::ToolPipeline, tools: ...)
    class AutoRefine
      def initialize(app, refiner:)
        @app = app
        @refiner = refiner
      end

      def call(env)
        @app.call(env)
        @refiner.turn_boundary!(messages: env[:messages])
        env
      end
    end
  end
end

__END__

require "brute/messages"

describe "prime_agent/middleware/auto_refine" do
  it "calls the refiner at each turn boundary with the messages" do
    calls = []
    refiner = Object.new
    refiner.define_singleton_method(:turn_boundary!) { |messages:| calls << messages }

    app = lambda do |env|
      env[:messages].assistant("done")
      env
    end
    middleware = PrimeAgent::Middleware::AutoRefine.new(app, refiner: refiner)

    env = { messages: Brute.log }
    env[:messages].user("hi")
    middleware.call(env)

    calls.length.should == 1
    calls.first.last.role.should == :assistant
  end

  it "propagates inner-stack failures without calling the refiner" do
    refiner = Object.new
    refiner.define_singleton_method(:turn_boundary!) { |messages:| raise "must not be called" }

    app = ->(_env) { raise "boom" }
    middleware = PrimeAgent::Middleware::AutoRefine.new(app, refiner: refiner)

    lambda { middleware.call({ messages: Brute.log }) }.should.raise(RuntimeError)
  end
end
