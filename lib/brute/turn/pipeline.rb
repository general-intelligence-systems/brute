# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  # Brute::Turn is the middleware machinery that runs a single "turn" — one
  # pass through a stack of middleware wrapped around a terminal app. An agent
  # turn and a tool call are both turns; they only differ in how they shape env
  # and what they return.
  #
  #   Brute::Turn::Pipeline       — the generic middleware chain (base class)
  #   Brute::Turn::AgentPipeline  — a turn shaped from a message log (LLM turn)
  #   Brute::Turn::ToolPipeline   — a turn shaped from tool arguments
  module Turn
    # Generic middleware machinery — literally a Rack::Builder. Rack already
    # gives us the whole chain (`@use` stack, reverse-inject in `to_app`,
    # `call`, and the `config.ru`-style loaders `parse_file`/`new_from_string`/
    # `app`), and its env is an opaque hash it just threads through — exactly
    # what a Brute turn needs. We inherit all of that and override only where
    # Brute's contract differs from HTTP's:
    #
    #   - `use`/`run` return `self` (Rack returns nil) so a pipeline stays
    #     chainable, e.g. `Pipeline.new.use(mw).run { ... }`, and so they carry
    #     explicit keyword args to the middleware constructor.
    #   - `build` aliases Rack's `to_app` — Brute's name for "nest the
    #     middleware around the terminal app and hand back the callable."
    #
    # Everything HTTP-specific Rack also carries (`map`/URLMap, `warmup`,
    # `freeze_app`) is inert here — no `map` is ever called, so `to_app`'s
    # map/warmup/freeze branches never fire.
    #
    # AgentPipeline *inherits* this (it is its own builder); ToolPipeline
    # *composes* one. Either way they shape their public arguments into an env
    # hash before running the chain.
    #
    #   class MyPipeline < Brute::Turn::Pipeline
    #     def call(input)
    #       env = { input: input, output: nil }
    #       super(env)
    #       env[:output]
    #     end
    #   end
    #
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
