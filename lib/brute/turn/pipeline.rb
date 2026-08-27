# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/hooks"

module Brute
  module Turn
    class Pipeline < ::Rack::Builder
      module Chainable
        include Brute::Hooks

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
        # Every layer announces itself: :middleware_added when it goes on the
        # stack, then :middleware_start and :middleware_end around its own work on each turn. Both
        # of those carry the middleware instance as self, and :middleware_end fires from
        # an ensure so a layer that raises is still reported.
        def use(middleware, *args, &block)
          tap do
            super
            hooks.emit(MIDDLEWARE_ADDED_EVENT, {}, middleware, *args)

            @use.pop.then do |builder|
              @use << lambda do |app|
                builder.call(app).tap do |layer|
                  layer.define_singleton_method(:call) do |env|
                    result = nil

                    # A layer is one call: what it emits, and what the layers
                    # below it emit, belong to this trace.
                    env.emit_trace do |env|
                      env.emit(MIDDLEWARE_START_EVENT, self)

                      # The layer's work is :middleware_duration's block, so its subscribers
                      # are handed how long this layer took — its own work plus
                      # everything below it. :middleware_end then marks the layer done,
                      # from an ensure so it lands even when the work raised.
                      begin
                        env.emit(MIDDLEWARE_DURATION_EVENT, self) { result = super(env) }
                      rescue => error
                        env.emit(MIDDLEWARE_FAILURE_EVENT, self, error)
                        raise
                      ensure
                        env.emit(MIDDLEWARE_END_EVENT, self)
                      end
                    end

                    result
                  end
                end
              end
            end
          end
        end
        # Keeps a trailing hash flagged as keywords through `super`, the way
        # Rack::Builder#use does — without it `use Mw, label: "x"` arrives at
        # the middleware's constructor as a positional Hash.
        ruby2_keywords(:use) if respond_to?(:ruby2_keywords, true)

        def run(app = nil, &block)
          tap do
            super
          end
        end

        # Subscribe a lifecycle hook (see Brute::Hooks):
        #
        #   Brute.agent
        #     .use(MaxProfit)
        #     .run(->(env) { ... })
        #     .on(:llm_start) { |env| ... }
        #     .on(:tool_approve) { |call| call[:name] != "exec" }
        #
        def on(...) = tap { hooks.on(...) }

        private


        public
      end

      include Chainable

      def self.new_from_string(builder_script, path = "(rackup)", **options)
        new(**options).tap do |builder|
          eval(builder_script, ::Rack::BUILDER_TOPLEVEL_BINDING.call(builder), path) # rubocop:disable Security/Eval
        end
      end

      # Brute's name for Rack's `to_app`
      alias_method :build, :to_app

      def initialize(default_app = nil, hooks: Brute::Hooks::Registry.new, **options, &block)
        @hooks = hooks
        super(default_app, **options, &block)
      end

      attr_reader :hooks

      # Every way into a pipeline arrives at a Trace: what a caller hands over
      # is wrapped once, and a pipeline entered from inside another keeps the
      # trace it was already in.
      def call(env)
        env.is_a?(Brute::Hooks::Trace) ? super : super(Brute::Hooks::Trace.new(env, hooks: hooks))
      end
    end
  end
end

__END__

describe "brute/turn/pipeline" do
  it "announces a layer when it is added, then on the way in and out of every turn" do
    seen = []
    hooks = Brute::Hooks::Registry.new
    hooks.on(Brute::Hooks::MIDDLEWARE_ADDED_EVENT) { |env, mw, *args| seen << [:added, env, mw, args] }
    hooks.on(Brute::Hooks::MIDDLEWARE_START_EVENT) { |_env, layer| seen << [:middleware_start, layer.class] }
    hooks.on(Brute::Hooks::MIDDLEWARE_DURATION_EVENT) { |_env, started, finished, layer| seen << [:middleware_duration, layer.class, finished >= started] }
    hooks.on(Brute::Hooks::MIDDLEWARE_END_EVENT) { |_env, layer| seen << [:middleware_end, layer.class] }

    labeller = Class.new do
      def initialize(app, label:); @app = app; @label = label; end
      def call(env); @app.call(env); end
    end

    pipeline = Brute::Turn::Pipeline.new
    pipeline.instance_variable_set(:@hooks, hooks)
    pipeline.use labeller, label: "outer"
    pipeline.run ->(env) { env }
    pipeline.call({ hooks: hooks })

    seen.first.should == [:added, {}, labeller, [{ label: "outer" }]]
    seen[1].should == [:middleware_start, labeller]
    seen[2].should == [:middleware_duration, labeller, true]
    seen[3].should == [:middleware_end, labeller]
  end

  it "reports a layer that raises through :middleware_end anyway" do
    seen = []

    boom = Class.new do
      def initialize(app); @app = app; end
      def call(_env); raise "boom"; end
    end

    pipeline = Brute::Turn::Pipeline.new
    pipeline.on(Brute::Hooks::MIDDLEWARE_END_EVENT) { |_env, layer| seen << layer.class }
    pipeline.use boom
    pipeline.run Object.new.tap { |o| o.define_singleton_method(:call) { |env| env } }
    begin
      pipeline.call({})
    rescue RuntimeError
      nil
    end

    seen.should == [boom]
  end

  it "wraps what it is called with in a trace, so a layer emits without being given anything" do
    seen = []
    quiet = Class.new do
      def initialize(app); @app = app; end
      def call(env); env.emit(:ping, :from_layer); @app.call(env); end
    end

    pipeline = Brute::Turn::Pipeline.new
    pipeline.on(:ping) { |env, extra, id| seen << [env[:said], extra, id] }
    pipeline.use quiet
    pipeline.run Object.new.tap { |o| o.define_singleton_method(:call) { |env| env } }
    pipeline.call({ said: "hello" })

    said, extra, id = seen.first
    said.should == "hello"
    extra.should == :from_layer
    id.should.not.be.nil

    # A lambda is a layer like any other now: it is handed the trace as its env.
    answered = []
    Brute::Turn::Pipeline.new.tap do |lambdas|
      lambdas.on(:ping) { |_env, extra| answered << extra }
      lambdas.run ->(env) { env.emit(:ping, :from_lambda); env }
      lambdas.call({})
    end
    answered.should == [:from_lambda]

    # Given a registry it uses that one rather than building its own, so a
    # nested pipeline reports to the agent that owns it.
    shared = Brute::Hooks::Registry.new
    Brute::Turn::Pipeline.new(hooks: shared).hooks.equal?(shared).should.be.true
  end


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
