# frozen_string_literal: true

module Brute
  # Rack-style middleware pipeline for LLM calls.
  #
  # Each middleware wraps the next, forming an onion model:
  #
  #   Tracing → Retry → DoomLoop → Reasoning → [LLM Call] → Reasoning → DoomLoop → Retry → Tracing
  #
  # The innermost "app" is the actual LLM call. Each middleware can:
  #   - Modify the env (context, params) BEFORE the call   (pre-processing)
  #   - Modify or inspect the response AFTER the call       (post-processing)
  #   - Short-circuit (return without calling inner app)
  #   - Retry (call inner app multiple times)
  #
  # ## The env hash
  #
  #   {
  #     context:   LLM::Context,     # conversation state
  #     provider:  LLM::Provider,    # the LLM provider
  #     input:     <prompt/results>,  # what to pass to context.talk()
  #     tools:     [Tool, ...],       # tool classes
  #     params:    {},                # extra LLM call params (reasoning config, etc.)
  #     metadata:  {},                # shared scratchpad for middleware state
  #     callbacks: {},                # :on_content, :on_tool_call_start, :on_tool_result
  #   }
  #
  # ## The response
  #
  #   The return value of call(env) is the LLM::Message from context.talk().
  #
  # ## Building a pipeline
  #
  #   pipeline = Brute::Pipeline.new do
  #     use Brute::Middleware::Tracing, logger: logger
  #     use Brute::Middleware::Retry, max_attempts: 3
  #     use Brute::Middleware::SessionPersistence, session: session
  #     run Brute::Middleware::LLMCall.new
  #   end
  #
  #   response = pipeline.call(env)
  #
  class Pipeline
    def initialize(&block)
      @middlewares = []
      @app = nil
      instance_eval(&block) if block
    end

    # Register a middleware class.
    # The class must implement `initialize(app, *args, **kwargs)` and `call(env)`.
    def use(klass, *args, **kwargs, &block)
      @middlewares << [klass, args, kwargs, block]
      self
    end

    # Set the terminal app (innermost handler).
    def run(app)
      @app = app
      self
    end

    # Build the full middleware chain and call it.
    def call(env)
      build.call(env)
    end

    # Build the chain without calling it. Useful for inspection or caching.
    def build
      raise "Pipeline has no terminal app — call `run` first" unless @app

      @middlewares.reverse.inject(@app) do |inner, (klass, args, kwargs, block)|
        if block
          klass.new(inner, *args, **kwargs, &block)
        else
          klass.new(inner, *args, **kwargs)
        end
      end
    end
  end
end
