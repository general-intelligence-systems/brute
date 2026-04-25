require_relative 'middleware/base'
require_relative 'middleware/llm_call'
require_relative 'middleware/retry'
require_relative 'middleware/doom_loop_detection'
require_relative 'middleware/token_tracking'
require_relative 'middleware/compaction_check'
require_relative 'middleware/session_persistence'
require_relative 'middleware/message_tracking'
require_relative 'middleware/tracing'
require_relative 'middleware/tool_error_tracking'
require_relative 'middleware/reasoning_normalizer'
require_relative "middleware/tool_use_guard"
require_relative "middleware/otel"
require_relative "middleware/max_iterations"
require_relative "middleware/tool_result_prep"
require_relative "middleware/pending_tool_collection"
require_relative "middleware/question"
require_relative "middleware/tool_call"

module Brute
  module Middleware
    # Rack-style middleware stack for LLM calls.
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
    #     provider:           LLM::Provider,    # the LLM provider
    #     model:              String|nil,       # model override
    #     input:              <prompt/results>, # what to pass to LLM
    #     tools:              [Tool, ...],      # tool classes
    #     messages:           [LLM::Message],   # conversation history (Brute-owned)
    #     stream:             AgentStream|nil,  # streaming bridge
    #     params:             {},               # extra LLM call params
    #     metadata:           {},               # shared scratchpad for middleware state
    #     callbacks:          {},               # :on_content, :on_tool_call_start, :on_tool_result
    #     tool_results:       Array|nil,        # tool results from previous iteration (set by ToolResultPrep)
    #     streaming:          Boolean,          # whether streaming is active
    #     should_exit:        Hash|nil,         # exit signal from middleware
    #     pending_functions:  [LLM::Function],  # tool calls from last LLM response (set by LLMCall)
    #     pending_tools:      Array,            # normalized [(fn, err), ...] pairs (set by PendingToolCollection)
    #     tool_results_queue: Array|nil,        # accumulated tool results (set by Question/ToolCall middleware)
    #     turn:               AgentTurn::Base,  # the agent turn step instance (provides sub-queue + reset)
    #   }
    #
    # ## The response
    #
    #   The return value of call(env) is the LLM::Message from context.talk().
    #
    # ## Building a stack
    #
    #   stack = Brute::Middleware::Stack.new do
    #     use Brute::Middleware::Tracing, logger: logger
    #     use Brute::Middleware::Retry, max_attempts: 3
    #     use Brute::Middleware::SessionPersistence, session: session
    #     run Brute::Middleware::LLMCall.new
    #   end
    #
    #   response = stack.call(env)
    #
    class Stack
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
        raise "Stack has no terminal app — call `run` first" unless @app

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

  # Legacy alias
  Pipeline = Middleware::Stack
end

test do
  require_relative "../../spec/support/mock_provider"
  require_relative "../../spec/support/mock_response"

  def make_env(provider:, input:)
    { provider: provider, model: nil, input: input, tools: [], messages: [],
      stream: nil, params: {}, metadata: {}, callbacks: {}, tool_results: nil,
      streaming: false, should_exit: nil, pending_functions: [] }
  end

  it "full stack passes env through all middleware" do
    provider = MockProvider.new
    session = Struct.new(:saved) { def save_messages(m); self.saved = m; end }.new
    compactor = Object.new
    compactor.define_singleton_method(:should_compact?) { |_msgs, **_| false }
    log_output = StringIO.new

    stack = Brute::Middleware::Stack.new
    stack.use(Brute::Middleware::Tracing, logger: Logger.new(log_output))
    stack.use(Brute::Middleware::Retry, max_attempts: 3, base_delay: 2)
    stack.use(Brute::Middleware::SessionPersistence, session: session)
    stack.use(Brute::Middleware::TokenTracking)
    stack.use(Brute::Middleware::CompactionCheck, compactor: compactor, system_prompt: "sys")
    stack.use(Brute::Middleware::ToolErrorTracking)
    stack.use(Brute::Middleware::DoomLoopDetection, threshold: 3)
    stack.use(Brute::Middleware::ToolUseGuard)
    stack.run(Brute::Middleware::LLMCall.new)

    env = make_env(provider: provider, input: "hello")
    result = stack.call(env)
    result.should.not.be.nil
  end

  it "stack populates timing metadata" do
    provider = MockProvider.new
    session = Struct.new(:saved) { def save_messages(m); self.saved = m; end }.new

    stack = Brute::Middleware::Stack.new
    stack.use(Brute::Middleware::Tracing, logger: Logger.new(StringIO.new))
    stack.use(Brute::Middleware::SessionPersistence, session: session)
    stack.use(Brute::Middleware::TokenTracking)
    stack.run(Brute::Middleware::LLMCall.new)

    env = make_env(provider: provider, input: "hello")
    stack.call(env)
    env[:metadata][:timing][:llm_call_count].should == 1
  end

  it "stack populates token metadata" do
    provider = MockProvider.new
    session = Struct.new(:saved) { def save_messages(m); self.saved = m; end }.new

    stack = Brute::Middleware::Stack.new
    stack.use(Brute::Middleware::Tracing, logger: Logger.new(StringIO.new))
    stack.use(Brute::Middleware::SessionPersistence, session: session)
    stack.use(Brute::Middleware::TokenTracking)
    stack.run(Brute::Middleware::LLMCall.new)

    env = make_env(provider: provider, input: "hello")
    stack.call(env)
    env[:metadata][:tokens][:total_input].should.be > 0
  end

  it "raises when no terminal app is set" do
    stack = Brute::Middleware::Stack.new
    stack.use(Brute::Middleware::TokenTracking)
    lambda { stack.call({}) }.should.raise(RuntimeError)
  end

  it "legacy Brute::Pipeline alias works" do
    Brute::Pipeline.should == Brute::Middleware::Stack
  end
end
