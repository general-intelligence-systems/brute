module Brute
  class Agent
    def initialize(**config, &block)
      @provider = config[:provider]
      @model    = config[:model]
      @tools    = config[:tools]

      @middlewares = []
      @app = nil

      instance_eval(&block) if block_given?
    end

    # Register a middleware class.
    #
    # The class must implement:
    #   `initialize(app, *args, **kwargs)` and `call(env)`.
    #
    def use(klass, *args, **kwargs, &block)
      tap do
        @middlewares << [klass, args, kwargs, block]
      end
    end

    # Set the terminal app (innermost handler).
    def run(app)
      tap do
        @app = app
      end
    end

    def call(session, events: NullSink.new)
      env = {
        messages: session,
        provider: @provider,
        model:    @model,
        tools:    @tools,
        events:   events,
        metadata: {},
        system_prompt: "",
        current_iteration: 1,
      }
      build.call(env)
      session
    end

    class NullSink
      def <<(_event); self; end
    end

    # Build the chain without calling it. Useful for inspection or caching.
    def build
      if @app
        @middlewares.reverse.inject(@app) do |inner, (klass, args, kwargs, block)|
          if block
            klass.new(inner, *args, **kwargs, &block)
          else
            klass.new(inner, *args, **kwargs)
          end
        end
      else
        raise "Stack has no terminal app — call `run` first"
      end
    end
  end
end

test do
  it "can run a stack" do
    # simple test to check it can run
  end

  it "returns the env after calling" do
    # should return modified env after calling
  end
end

