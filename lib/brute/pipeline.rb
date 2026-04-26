# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  # Generic middleware machinery. Builds a chain of middleware around
  # a terminal app, exposes `call(env)` to invoke it.
  #
  # Subclasses (Agent, Tool) override `call` to translate their public
  # arguments into an env hash, then delegate to super.
  #
  #   class MyPipeline < Brute::Pipeline
  #     def call(input)
  #       env = { input: input, output: nil }
  #       super(env)
  #       env[:output]
  #     end
  #   end
  #
  class Pipeline
    def initialize(&block)
      @middlewares = []
      @app = nil
      instance_eval(&block) if block_given?
    end

    # Register a middleware class.
    # The class must implement `initialize(app, *args, **kwargs)` and `call(env)`.
    def use(klass, *args, **kwargs, &block)
      tap { @middlewares << [klass, args, kwargs, block] }
    end

    # Set the terminal app (innermost handler).
    # Accepts an instance (anything responding to #call(env)) or a class.
    def run(app)
      tap { @app = app }
    end

    # Invoke the chain. Subclasses typically override this to shape env
    # and extract a return value.
    def call(env)
      build.call(env)
    end

    # Build the chain without calling it. Useful for inspection or caching.
    def build
      raise "Stack has no terminal app — call `run` first" unless @app

      @middlewares.reverse.inject(@app) do |inner, (klass, args, kwargs, block)|
        if block
          klass.new(inner, *args, **kwargs, &block)
        else
          klass.new(inner, *args, **kwargs)
        end
      end
    end

    # Default null sink for env[:events] — swallows anything pushed to it.
    class NullSink
      def <<(_event); self; end
    end
  end
end

test do
  it "builds and calls a chain" do
    seen = []
    inc = Class.new do
      def initialize(app, label:); @app = app; @label = label; end
      def call(env); env[:trace] << @label; @app.call(env); env[:trace] << "#{@label}-after"; end
    end

    pipeline = Brute::Pipeline.new do
      use inc, label: "outer"
      use inc, label: "inner"
      run ->(env) { env[:trace] << "core" }
    end

    env = { trace: [] }
    pipeline.call(env)
    env[:trace].should == ["outer", "inner", "core", "inner-after", "outer-after"]
  end

  it "raises when run was never called" do
    lambda { Brute::Pipeline.new.call({}) }.should.raise(RuntimeError)
  end

  it "accepts a callable as the terminal app" do
    pipeline = Brute::Pipeline.new do
      run ->(env) { env[:result] = 42 }
    end
    env = {}
    pipeline.call(env)
    env[:result].should == 42
  end
end
