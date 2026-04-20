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

if __FILE__ == $0
  require_relative "../../spec/spec_helper"

  RSpec.describe "Middleware Pipeline Integration" do
    let(:provider) { MockProvider.new }
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:session) { double("session", save: nil) }
    let(:compactor) { double("compactor", should_compact?: false) }

    describe "full orchestrator pipeline" do
      it "passes env through all middleware and returns the response" do
        response = MockResponse.new(content: "integrated response")
        allow(provider).to receive(:complete).and_return(response)

        ctx = LLM::Context.new(provider, tools: [])
        prompt = ctx.prompt { |p| p.system("sys"); p.user("hello") }

        pipeline = Brute::Pipeline.new
        pipeline.use(Brute::Middleware::Tracing, logger: logger)
        pipeline.use(Brute::Middleware::Retry, max_attempts: 3, base_delay: 2)
        pipeline.use(Brute::Middleware::SessionPersistence, session: session)
        pipeline.use(Brute::Middleware::TokenTracking)
        pipeline.use(Brute::Middleware::CompactionCheck, compactor: compactor, system_prompt: "sys", tools: [])
        pipeline.use(Brute::Middleware::ToolErrorTracking)
        pipeline.use(Brute::Middleware::DoomLoopDetection, threshold: 3)
        pipeline.use(Brute::Middleware::ToolUseGuard)
        pipeline.run(Brute::Middleware::LLMCall.new)

        env = {
          context: ctx,
          provider: provider,
          input: prompt,
          tools: [],
          params: {},
          metadata: {},
          callbacks: {},
          tool_results: nil,
          streaming: false,
        }

        result = pipeline.call(env)

        expect(result).not_to be_nil
        expect(env[:metadata][:timing]).to include(:llm_call_count, :total_llm_elapsed)
        expect(env[:metadata][:tokens]).to include(:total_input, :total_output, :call_count)
        expect(session).to have_received(:save)
        expect(log_output.string).to include("LLM call #1")
      end
    end

    describe "Retry + Tracing combo" do
      it "Tracing sees the full elapsed time including retries" do
        call_count = 0
        response = MockResponse.new(content: "recovered")

        allow(provider).to receive(:complete) do |*_args|
          call_count += 1
          raise LLM::RateLimitError, "rate limited" if call_count <= 1
          response
        end

        ctx = LLM::Context.new(provider, tools: [])
        prompt = ctx.prompt { |p| p.system("sys"); p.user("hi") }

        pipeline = Brute::Pipeline.new
        pipeline.use(Brute::Middleware::Tracing, logger: logger)
        pipeline.use(Brute::Middleware::Retry, max_attempts: 3, base_delay: 0)
        pipeline.run(Brute::Middleware::LLMCall.new)

        env = {
          context: ctx,
          provider: provider,
          input: prompt,
          tools: [],
          params: {},
          metadata: {},
          callbacks: {},
          tool_results: nil,
          streaming: false,
        }

        result = pipeline.call(env)

        expect(result).not_to be_nil
        expect(env[:metadata][:timing][:llm_call_count]).to eq(1)
      end
    end

    describe "TokenTracking + SessionPersistence combo" do
      it "session receives save after tokens are tracked" do
        response = MockResponse.new(content: "tracked and saved")
        allow(provider).to receive(:complete).and_return(response)

        ctx = LLM::Context.new(provider, tools: [])
        prompt = ctx.prompt { |p| p.system("sys"); p.user("hi") }

        save_args = []
        allow(session).to receive(:save) { |ctx_arg| save_args << ctx_arg }

        pipeline = Brute::Pipeline.new
        pipeline.use(Brute::Middleware::SessionPersistence, session: session)
        pipeline.use(Brute::Middleware::TokenTracking)
        pipeline.run(Brute::Middleware::LLMCall.new)

        env = {
          context: ctx,
          provider: provider,
          input: prompt,
          tools: [],
          params: {},
          metadata: {},
          callbacks: {},
          tool_results: nil,
          streaming: false,
        }

        pipeline.call(env)

        expect(env[:metadata][:tokens]).to include(:total_input)
        expect(save_args.size).to eq(1)
      end
    end

    describe "Pipeline builder" do
      it "raises when no terminal app is set" do
        pipeline = Brute::Pipeline.new
        pipeline.use(Brute::Middleware::TokenTracking)

        expect { pipeline.call({}) }.to raise_error(RuntimeError, /no terminal app/)
      end
    end
  end
end
