# frozen_string_literal: true

require "bundler/setup"
require "brute"

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
  #     provider:          LLM::Provider,    # the LLM provider
  #     model:             String|nil,       # model override
  #     input:             <prompt/results>, # what to pass to LLM
  #     tools:             [Tool, ...],      # tool classes
  #     messages:          [LLM::Message],   # conversation history (Brute-owned)
  #     stream:            AgentStream|nil,  # streaming bridge
  #     params:            {},               # extra LLM call params
  #     metadata:          {},               # shared scratchpad for middleware state
  #     callbacks:         {},               # :on_content, :on_tool_call_start, :on_tool_result
  #     tool_results:      Array|nil,        # tool results from previous iteration
  #     streaming:         Boolean,          # whether streaming is active
  #     should_exit:       Hash|nil,         # exit signal from middleware
  #     pending_functions: [LLM::Function],  # tool calls from last LLM response
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

test do
  require_relative "../../spec/support/mock_provider"
  require_relative "../../spec/support/mock_response"

  def make_env(provider:, input:)
    { provider: provider, model: nil, input: input, tools: [], messages: [],
      stream: nil, params: {}, metadata: {}, callbacks: {}, tool_results: nil,
      streaming: false, should_exit: nil, pending_functions: [] }
  end

  it "full pipeline passes env through all middleware" do
    provider = MockProvider.new
    session = Struct.new(:saved) { def save_messages(m); self.saved = m; end }.new
    compactor = Object.new
    compactor.define_singleton_method(:should_compact?) { |_msgs, **_| false }
    log_output = StringIO.new

    pipeline = Brute::Pipeline.new
    pipeline.use(Brute::Middleware::Tracing, logger: Logger.new(log_output))
    pipeline.use(Brute::Middleware::Retry, max_attempts: 3, base_delay: 2)
    pipeline.use(Brute::Middleware::SessionPersistence, session: session)
    pipeline.use(Brute::Middleware::TokenTracking)
    pipeline.use(Brute::Middleware::CompactionCheck, compactor: compactor, system_prompt: "sys")
    pipeline.use(Brute::Middleware::ToolErrorTracking)
    pipeline.use(Brute::Middleware::DoomLoopDetection, threshold: 3)
    pipeline.use(Brute::Middleware::ToolUseGuard)
    pipeline.run(Brute::Middleware::LLMCall.new)

    env = make_env(provider: provider, input: "hello")
    result = pipeline.call(env)
    result.should.not.be.nil
  end

  it "pipeline populates timing metadata" do
    provider = MockProvider.new
    session = Struct.new(:saved) { def save_messages(m); self.saved = m; end }.new

    pipeline = Brute::Pipeline.new
    pipeline.use(Brute::Middleware::Tracing, logger: Logger.new(StringIO.new))
    pipeline.use(Brute::Middleware::SessionPersistence, session: session)
    pipeline.use(Brute::Middleware::TokenTracking)
    pipeline.run(Brute::Middleware::LLMCall.new)

    env = make_env(provider: provider, input: "hello")
    pipeline.call(env)
    env[:metadata][:timing][:llm_call_count].should == 1
  end

  it "pipeline populates token metadata" do
    provider = MockProvider.new
    session = Struct.new(:saved) { def save_messages(m); self.saved = m; end }.new

    pipeline = Brute::Pipeline.new
    pipeline.use(Brute::Middleware::Tracing, logger: Logger.new(StringIO.new))
    pipeline.use(Brute::Middleware::SessionPersistence, session: session)
    pipeline.use(Brute::Middleware::TokenTracking)
    pipeline.run(Brute::Middleware::LLMCall.new)

    env = make_env(provider: provider, input: "hello")
    pipeline.call(env)
    env[:metadata][:tokens][:total_input].should.be > 0
  end

  it "raises when no terminal app is set" do
    pipeline = Brute::Pipeline.new
    pipeline.use(Brute::Middleware::TokenTracking)
    lambda { pipeline.call({}) }.should.raise(RuntimeError)
  end
end
