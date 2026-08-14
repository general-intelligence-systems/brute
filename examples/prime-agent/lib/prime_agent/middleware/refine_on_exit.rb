# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # Stage 4 — distill lessons into the continual harness when the run ends.
    #
    # prime-agent refines at compaction checkpoints; a one-shot `agent.start`
    # has exactly one turn, so the equivalent checkpoint is the end of the
    # run. After the inner stack returns, this middleware hands the full
    # trajectory to `Refiner#refine_on_exit`, which drains a pending kernel
    # `refine.run` request or runs the final distillation pass. Disable with
    # `BRUTE_REFINE_FINAL=0`.
    #
    # Place it outside the turn loop (runs once), inside KernelLifecycle:
    #
    #   .use(PrimeAgent::Middleware::KernelLifecycle, provisioner: provisioner)
    #   .use(PrimeAgent::Middleware::RefineOnExit, refiner: refiner)
    #   .use(Brute::Middleware::SystemPrompt, ...)
    class RefineOnExit
      def initialize(app, refiner:)
        @app = app
        @refiner = refiner
      end

      def call(env)
        @app.call(env)
      ensure
        # The refiner never raises; a crashed run still gets the distillation
        # chance (its trajectory is simply shorter).
        @refiner.refine_on_exit(messages: env[:messages] || [])
      end
    end
  end
end

__END__

require "brute/messages"

describe "prime_agent/middleware/refine_on_exit" do
  FakeRefiner = Class.new do
    attr_reader :calls

    def initialize
      @calls = []
    end

    def refine_on_exit(messages:)
      @calls << messages
    end
  end

  it "runs the final distill with the trajectory after the run" do
    refiner = FakeRefiner.new
    app = lambda do |env|
      env[:messages].assistant("done")
      env
    end
    middleware = PrimeAgent::Middleware::RefineOnExit.new(app, refiner: refiner)

    env = { messages: Brute.log }
    env[:messages].user("task")
    middleware.call(env)

    refiner.calls.length.should == 1
    refiner.calls.first.last.role.should == :assistant
  end

  it "still runs when the inner stack raises" do
    refiner = FakeRefiner.new
    app = ->(_env) { raise "boom" }
    middleware = PrimeAgent::Middleware::RefineOnExit.new(app, refiner: refiner)

    lambda { middleware.call({ messages: Brute.log }) }.should.raise(RuntimeError)
    refiner.calls.length.should == 1
  end
end
