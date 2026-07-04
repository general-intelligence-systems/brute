# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Turn
    class Pipeline < ::Rack::Builder
      module Chainable
        # Enables the following syntax:
        #
        #   Brute.agent
        #     .use(UltraSecurity)
        #     .use(MaxProfit)
        #     .use(DontTellMom)
        #     .run -> (env) {
        #       RubyLLM.chat.ask("How to make money?")
        #     }
        #
        def use(...) = tap { super }
        def run(...) = tap { super }
      end

      include Chainable

      # Brute's name for Rack's `to_app`: nest the middleware around the
      # terminal app and return the runnable callable. Raises (via `to_app`)
      # when `run` was never called.
      alias_method :build, :to_app

      # Default null sink for env[:events] — swallows anything pushed to it.
      class NullSink
        def <<(_event); self; end
      end
    end
  end
end

__END__

describe "brute/turn/pipeline" do
  it "builds and calls a chain" do
    seen = []
    inc = Class.new do
      def initialize(app, label:); @app = app; @label = label; end
      def call(env); env[:trace] << @label; @app.call(env); env[:trace] << "#{@label}-after"; end
    end

    pipeline = Brute::Turn::Pipeline.new do
      use inc, label: "outer"
      use inc, label: "inner"
      run ->(env) { env[:trace] << "core" }
    end

    env = { trace: [] }
    pipeline.call(env)
    env[:trace].should == ["outer", "inner", "core", "inner-after", "outer-after"]
  end

  it "raises when run was never called" do
    lambda { Brute::Turn::Pipeline.new.call({}) }.should.raise(RuntimeError)
  end

  it "accepts a callable as the terminal app" do
    pipeline = Brute::Turn::Pipeline.new do
      run ->(env) { env[:result] = 42 }
    end
    env = {}
    pipeline.call(env)
    env[:result].should == 42
  end

  it "run accepts a block terminal and stays chainable" do
    pipeline = Brute::Turn::Pipeline.new.use(Class.new do
      def initialize(app); @app = app; end
      def call(env); env[:trace] << "mw"; @app.call(env); end
    end).run { |env| env[:trace] << "core" }

    env = { trace: [] }
    pipeline.call(env)
    env[:trace].should == ["mw", "core"]
  end
end
