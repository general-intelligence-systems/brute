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
        # stack, then :enter and :exit around its own work on each turn. Both
        # of those carry the middleware instance as self, and :exit fires from
        # an ensure so a layer that raises is still reported.
        def use(middleware, *args, &block)
          tap do
            super
            hooks.emit(MIDDLEWARE_ADDED_EVENT, {}, middleware, *args)

            builder = @use.pop
            @use << lambda do |app|
              bind_emitter(builder.call(app)).tap do |layer|
                layer.define_singleton_method(:call) do |env|
                  emit(ENTER_EVENT, env, self)

                  # The layer's work is :duration's block, so its subscribers
                  # are handed how long this layer took — its own work plus
                  # everything below it. :exit then marks the layer done,
                  # from an ensure so it lands even when the work raised.
                  result = nil
                  begin
                    emit(DURATION_EVENT, env, self) { result = super(env) }
                  ensure
                    emit(EXIT_EVENT, env, self)
                  end

                  result
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
            bind_emitter(app) unless app.nil?
            super
          end
        end

        # Subscribe a lifecycle hook (see Brute::Hooks):
        #
        #   Brute.agent
        #     .use(MaxProfit)
        #     .run(->(env) { ... })
        #     .on(:before_llm) { |env| ... }
        #     .on(:approve_tool) { |call| call[:name] != "exec" }
        #
        def on(...) = tap { hooks.on(...) }

        private

          # Bind an emit() to this builder's store, so a layer fires events at
          # the pipeline it belongs to rather than fishing them out of env.
          def bind_emitter(object)
            if object.is_a?(Proc)
              warn("brute: #{self.class} was given a lambda, which cannot be given an emit — its events will not fire")
              return object
            end

            if object.respond_to?(:emit)
              raise ArgumentError, "#{object.class} already defines #emit, so the pipeline will not bind its own over it"
            end

            store = hooks
            object.define_singleton_method(:emit) do |event, env, *extras, &work|
              store.emit(event, env, *extras, &work)
            end
            object
          end

        public
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
  it "announces a layer when it is added, then on the way in and out of every turn" do
    seen = []
    hooks = Brute::Hooks.new
    hooks.on(Brute::Hooks::MIDDLEWARE_ADDED_EVENT) { |env, mw, *args| seen << [:added, env, mw, args] }
    hooks.on(Brute::Hooks::ENTER_EVENT) { |_env, layer| seen << [:enter, layer.class] }
    hooks.on(Brute::Hooks::DURATION_EVENT) { |_env, started, finished, layer| seen << [:duration, layer.class, finished >= started] }
    hooks.on(Brute::Hooks::EXIT_EVENT) { |_env, layer| seen << [:exit, layer.class] }

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
    seen[1].should == [:enter, labeller]
    seen[2].should == [:duration, labeller, true]
    seen[3].should == [:exit, labeller]
  end

  it "reports a layer that raises through :exit anyway" do
    seen = []

    boom = Class.new do
      def initialize(app); @app = app; end
      def call(_env); raise "boom"; end
    end

    pipeline = Brute::Turn::Pipeline.new
    pipeline.on(Brute::Hooks::EXIT_EVENT) { |_env, layer| seen << layer.class }
    pipeline.use boom
    pipeline.run Object.new.tap { |o| o.define_singleton_method(:call) { |env| env } }
    begin
      pipeline.call({})
    rescue RuntimeError
      nil
    end

    seen.should == [boom]
  end

  it "binds emit to its own store, warns for a lambda, and refuses to shadow an existing emit" do
    seen = []
    quiet = Class.new do
      def initialize(app); @app = app; end
      def call(env); emit(:ping, env, :from_layer); @app.call(env); end
    end

    pipeline = Brute::Turn::Pipeline.new
    pipeline.on(:ping) { |env, extra| seen << [env, extra] }
    pipeline.use quiet
    pipeline.run Object.new.tap { |o| o.define_singleton_method(:call) { |env| env } }
    pipeline.call({})
    seen.should == [[{}, :from_layer]]

    # A lambda cannot reach the bound method, so it is warned about, not patched.
    warned = []
    lambda_pipeline = Brute::Turn::Pipeline.new
    lambda_pipeline.define_singleton_method(:warn) { |message| warned << message }
    lambda_pipeline.run ->(env) { env }
    warned.size.should == 1
    warned.first.should.match(/lambda/)

    # An object that already answers to emit is left alone, loudly.
    emitter = Class.new do
      def initialize(app); @app = app; end
      def emit(*); end
      def call(env); env; end
    end
    # The layer is constructed when the stack is built, so that is when the
    # collision is discovered.
    shadowing = Brute::Turn::Pipeline.new
    shadowing.use emitter
    shadowing.run Object.new.tap { |o| o.define_singleton_method(:call) { |env| env } }
    should.raise(ArgumentError) { shadowing.call({}) }
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
