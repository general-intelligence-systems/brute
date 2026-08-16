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
        #       your_llm_library.complete("How to make money?")
        #     }
        #
        def use(...) = tap { super }
        def run(...) = tap { super }

        # Subscribe a lifecycle hook (see Brute::Hooks):
        #
        #   Brute.agent
        #     .use(MaxProfit)
        #     .run(->(env) { ... })
        #     .on(:before_llm) { |env| ... }
        #     .on(:approve_tool) { |call| call[:name] != "exec" }
        #
        def on(...) = tap { hooks.on(...) }
      end

      include Chainable

      # Rack's `new_from_string` evaluates the script then returns `to_app` —
      # the built callable. An agent, though, is the *builder*: you `.start` it,
      # and it may be re-`use`d or served through the Rack adapter. So evaluate
      # the script against a fresh builder and hand back the builder itself.
      # This also backs `parse_file` (→ `load_file` → here), so
      # `AgentPipeline.parse_file("agent.ru").start(prompt)` works as documented.
      def self.new_from_string(builder_script, path = "(rackup)", **options)
        builder = new(**options)
        eval(builder_script, ::Rack::BUILDER_TOPLEVEL_BINDING.call(builder), path) # rubocop:disable Security/Eval
        builder
      end

      # Brute's name for Rack's `to_app`: nest the middleware around the
      # terminal app and return the runnable callable. Raises (via `to_app`)
      # when `run` was never called.
      alias_method :build, :to_app

      # The lifecycle-hook registry for this pipeline (see Brute::Hooks).
      def hooks
        @hooks ||= Brute::Hooks.new
      end

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
