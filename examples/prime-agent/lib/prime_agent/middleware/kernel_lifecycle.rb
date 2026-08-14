# frozen_string_literal: true

module PrimeAgent
  module Middleware
    # Stage 1 — kernel lifecycle. Owns the OS boundary of the IRuby kernel
    # process: when the run finishes (or crashes), the kernel is shut down
    # (shutdown_request → TERM → KILL in KernelManager#shutdown).
    #
    # Place it outermost in the pipeline so its ensure block runs last:
    #
    #   .use(PrimeAgent::Middleware::KernelLifecycle, provisioner: provisioner)
    class KernelLifecycle
      def initialize(app, provisioner:)
        @app = app
        @provisioner = provisioner
      end

      def call(env)
        @app.call(env)
      ensure
        @provisioner.shutdown
      end
    end
  end
end

__END__

describe "prime_agent/middleware/kernel_lifecycle" do
  FakeProvisioner = Class.new do
    attr_reader :shutdowns

    def initialize
      @shutdowns = 0
    end

    def shutdown
      @shutdowns += 1
    end
  end

  it "shuts the provisioner down after the run" do
    provisioner = FakeProvisioner.new
    app = ->(env) { env[:ran] = true }
    middleware = PrimeAgent::Middleware::KernelLifecycle.new(app, provisioner: provisioner)

    env = {}
    middleware.call(env)

    env[:ran].should.be.true
    provisioner.shutdowns.should == 1
  end

  it "still shuts down when the inner stack raises" do
    provisioner = FakeProvisioner.new
    app = ->(_env) { raise "boom" }
    middleware = PrimeAgent::Middleware::KernelLifecycle.new(app, provisioner: provisioner)

    lambda { middleware.call({}) }.should.raise(RuntimeError)
    provisioner.shutdowns.should == 1
  end
end
