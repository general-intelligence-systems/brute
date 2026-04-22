# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Loop
  # Factory + namespace for provider-specific agent turns.
  #
  # An agent turn sends a message to the LLM, iterates over tool calls
  # until there are none left, and returns the response. Each turn has
  # its own job queue for tool execution (ParallelQueue of ToolCallSteps).
  #
  # Usage:
  #
  #   step = AgentTurn.perform(agent:, session:, pipeline:, input:)
  #
  # AgentTurn.perform detects the provider from the agent and returns
  # the appropriate provider-specific Step subclass, already executed.
  # The returned step has .state, .result, .error, etc.
  #
  # Provider-specific subclasses live under AgentTurn:: and override
  # supported_messages to filter the session's message history per
  # provider capability.
  #
  module AgentTurn
    # Build and return the right AgentTurn step for this agent's provider.
    # Does NOT execute it — call step.call(task) yourself, or enqueue it.
    def self.new(agent:, session:, pipeline:, input: nil, callbacks: {}, **rest)
      klass = detect(agent.provider)
      klass.new(agent: agent, session: session, pipeline: pipeline, input: input, callbacks: callbacks, **rest)
    end

    # Build, execute inside a Sync block, return the finished step.
    def self.perform(agent:, session:, pipeline:, input: nil, callbacks: {}, **rest)
      step = self.new(agent: agent, session: session, pipeline: pipeline, input: input, callbacks: callbacks, **rest)
      Sync do
        step.call(Async::Task.current)
      end
      step
    end

    # Detect the right subclass from the provider.
    def self.detect(provider)
      if provider
        provider.class.name.to_s.downcase.then do |class_name|
          if class_name.include?("anthropic")
            Anthropic
          elsif class_name.include?("openai")
            OpenAI
          elsif class_name.include?("google") || class_name.include?("gemini")
            Google
          else
            Base
          end
        end
      else
        Base
      end
    end

    # The default implementation. Works for any provider.
    # Provider-specific subclasses override supported_messages
    # and anything else that differs.
    #
    # LLM::Context is built fresh for each pipeline call by the LLMCall
    # middleware. The agent turn owns the conversation state via
    # env[:messages] (an Array<LLM::Message>).
    #
    # Supports two modes:
    #
    #   Non-streaming (default): text arrives after the LLM call completes,
    #   on_content fires post-hoc via LLMCall middleware, tool calls come
    #   from env[:pending_functions].
    #
    #   Streaming: enabled when on_content or on_reasoning callbacks are
    #   present. Text/reasoning fire incrementally via AgentStream. Tool
    #   calls are deferred during the stream and collected afterward from
    #   the stream's pending_tools.
    #
    # Callbacks:
    #
    #   on_content:         ->(text) {}     # text chunk (streaming) or full text (non-streaming)
    #   on_reasoning:       ->(text) {}     # reasoning/thinking chunk (streaming only)
    #   on_tool_call_start: ->(batch) {}    # [{name:, arguments:}, ...] before tool execution
    #   on_tool_result:     ->(name, r) {}  # per-tool, after each completes
    #   on_question:        ->(questions, queue) {}  # interactive; push answers onto queue
    #
    class Base < Step
      MAX_ITERATIONS = 100

      attr_reader :agent, :session

      def initialize(agent:, session:, pipeline:, input: nil, callbacks: {}, **rest)
        super(**rest)
        @agent     = agent
        @session   = session
        @pipeline  = pipeline
        @input     = input
        @callbacks = callbacks

        # Create streaming bridge when content or reasoning callbacks are
        # present. The stream is passed into env so LLMCall can wire it
        # into each fresh LLM::Context.
        if @callbacks[:on_content] || @callbacks[:on_reasoning]
          @stream = AgentStream.new(
            on_content:   @callbacks[:on_content],
            on_reasoning: @callbacks[:on_reasoning],
            on_question:  @callbacks[:on_question],
          )
        end
      end

      def perform(task)
        env = build_env

        # First LLM call
        env[:input] = build_initial_input(@input)
        env[:tool_results] = nil
        response = @pipeline.call(env)

        iterations = 0
        while !env[:should_exit] &&
          (pending = collect_pending_tools(env)).any? &&
          iterations < MAX_ITERATIONS

          # Fire on_tool_call_start with the full batch
          @callbacks[:on_tool_call_start]&.call(
            pending.map { |fn, _| { name: fn.name, arguments: fn.arguments } }
          )

          # Partition: question tools run sequentially on this fiber,
          # all others run in parallel via the sub-queue.
          questions, others = pending.partition { |fn, _| fn.name == "question" }

          results = []

          # Questions first — sequential, blocking, with on_question fiber-local
          questions.each do |fn, err|
            if err
              @callbacks[:on_tool_result]&.call(err.name, result_value(err))
              results << err
            else
              Thread.current[:on_question] = @callbacks[:on_question]
              result = fn.call
              @callbacks[:on_tool_result]&.call(fn.name, result_value(result))
              results << result
            end
          end

          # Others — into the parallel queue
          if others.any?
            errors, executable = others.partition { |_, err| err }

            # Record pre-existing errors (from stream's on_tool_call)
            errors.each do |_, err|
              @callbacks[:on_tool_result]&.call(err.name, result_value(err))
              results << err
            end

            if executable.any?
              tool_steps = executable.map { |fn, _| ToolCallStep.new(function: fn) }
              tool_steps.each { |s| jobs(type: Brute::Queue::ParallelQueue) << s }
              jobs.drain

              tool_steps.each do |s|
                val = s.state == :completed ? s.result : s.error
                @callbacks[:on_tool_result]&.call(s.function.name, result_value(val))
                results << val
              end
            end
          end

          # Feed results back to LLM
          env[:input] = results
          env[:tool_results] = results.filter_map { |r|
            name = r.respond_to?(:name) ? r.name : "unknown"
            [name, result_value(r)]
          }
          response = @pipeline.call(env)

          # Re-create sub-queue for next iteration's tool calls
          @mutex.synchronize { @jobs = nil }
          iterations += 1
        end

        response
      end

      # Override in subclasses to filter message types per provider.
      # Default: all messages pass through.
      def supported_messages(messages)
        messages
      end

      private

      def build_env
        {
          provider:          @agent.provider,
          model:             @agent.model,
          input:             nil,
          tools:             @agent.tools,
          messages:          [],
          stream:            @stream,
          params:            {},
          metadata:          {},
          tool_results:      nil,
          streaming:         !!@stream,
          callbacks:         @callbacks,
          should_exit:       nil,
          pending_functions: [],
        }
      end

      def build_initial_input(user_message)
        sys = @agent.system_prompt
        LLM::Prompt.new(@agent.provider) do |p|
          p.system(sys) if sys
          p.user(user_message) if user_message
        end
      end

      # Collect pending tool calls from the stream (streaming mode) or
      # from env[:pending_functions] (set by LLMCall after each call).
      #
      # Returns [(function, error_or_nil), ...] pairs.
      # Clears the stream's deferred state after consumption.
      def collect_pending_tools(env)
        if @stream&.pending_tools&.any?
          @stream.pending_tools.dup.tap { @stream.clear_pending_tools! }
        elsif env[:pending_functions]&.any?
          env[:pending_functions].dup.tap { env[:pending_functions] = [] }.map { |fn| [fn, nil] }
        else
          []
        end
      end

      def result_value(result)
        result.respond_to?(:value) ? result.value : result
      end
    end

    # Provider-specific subclasses. Override supported_messages
    # or loop behavior as needed.

    class Anthropic < Base
    end

    class OpenAI < Base
    end

    class Google < Base
    end
  end
  end
end

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  class RecordingPipeline
    attr_reader :calls
    def initialize(responses: [])
      @responses = responses
      @calls = []
      @index = 0
    end

    def call(env)
      @calls << env[:input]
      resp = @responses[@index] || @responses.last
      @index += 1
      resp
    end
  end

  FakeResponse = Struct.new(:content)

  def make_agent(provider: MockProvider.new, tools: [])
    Brute::Agent.new(provider: provider, model: nil, tools: tools)
  end

  # -- factory detection --

  it "detects Base for unknown providers" do
    Brute::Loop::AgentTurn.detect(MockProvider.new).should == Brute::Loop::AgentTurn::Base
  end

  it "detects Anthropic from provider class name" do
    provider = MockProvider.new
    def provider.class; Class.new { def self.name; "LLM::Anthropic"; end }; end
    Brute::Loop::AgentTurn.detect(provider).should == Brute::Loop::AgentTurn::Anthropic
  end

  it "detects OpenAI from provider class name" do
    provider = MockProvider.new
    def provider.class; Class.new { def self.name; "LLM::OpenAI"; end }; end
    Brute::Loop::AgentTurn.detect(provider).should == Brute::Loop::AgentTurn::OpenAI
  end

  it "detects Google from provider class name" do
    provider = MockProvider.new
    def provider.class; Class.new { def self.name; "LLM::Google"; end }; end
    Brute::Loop::AgentTurn.detect(provider).should == Brute::Loop::AgentTurn::Google
  end

  # -- AgentTurn.new returns the right subclass --

  it "returns Base instance for unknown provider" do
    step = Brute::Loop::AgentTurn.new(
      agent: make_agent,
      session: Brute::Store::Session.new,
      pipeline: RecordingPipeline.new(responses: []),
      input: "hi",
    )
    step.should.be.kind_of Brute::Loop::AgentTurn::Base
  end

  # -- basic turn execution --

  it "calls the pipeline" do
    Sync do
      pipeline = RecordingPipeline.new(responses: [FakeResponse.new("hello")])
      step = Brute::Loop::AgentTurn.new(
        agent: make_agent,
        session: Brute::Store::Session.new,
        pipeline: pipeline,
        input: "hi",
      )
      step.call(Async::Task.current)
      pipeline.calls.size.should == 1
    end
  end

  it "returns the LLM response as result" do
    Sync do
      pipeline = RecordingPipeline.new(responses: [FakeResponse.new("world")])
      step = Brute::Loop::AgentTurn.new(
        agent: make_agent,
        session: Brute::Store::Session.new,
        pipeline: pipeline,
        input: "hi",
      )
      step.call(Async::Task.current)
      step.result.content.should == "world"
    end
  end

  it "transitions to completed" do
    Sync do
      pipeline = RecordingPipeline.new(responses: [FakeResponse.new("ok")])
      step = Brute::Loop::AgentTurn.new(
        agent: make_agent,
        session: Brute::Store::Session.new,
        pipeline: pipeline,
        input: "hi",
      )
      step.call(Async::Task.current)
      step.state.should == :completed
    end
  end

  # -- AgentTurn.perform convenience --

  it "perform returns a completed step" do
    pipeline = RecordingPipeline.new(responses: [FakeResponse.new("done")])
    step = Brute::Loop::AgentTurn.perform(
      agent: make_agent,
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    step.state.should == :completed
  end

  # -- cancellation --

  it "is cancellable when pending" do
    step = Brute::Loop::AgentTurn.new(
      agent: Brute::Agent.new(provider: nil, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: RecordingPipeline.new(responses: []),
      input: "hi",
    )
    step.cancel
    step.state.should == :cancelled
  end

  # -- system prompt from agent --

  it "uses agent system_prompt" do
    Sync do
      agent = Brute::Agent.new(
        provider: MockProvider.new,
        model: nil,
        tools: [],
        system_prompt: "You are a test bot",
      )
      pipeline = RecordingPipeline.new(responses: [FakeResponse.new("ok")])
      step = Brute::Loop::AgentTurn.new(
        agent: agent,
        session: Brute::Store::Session.new,
        pipeline: pipeline,
        input: "hi",
      )
      step.call(Async::Task.current)
      step.state.should == :completed
    end
  end

  # -- should_exit loop break --

  # A mock function that satisfies ToolCallStep's interface.
  LoopTestFunction = Struct.new(:id, :name, :arguments, keyword_init: true) do
    def call; self; end
    def value; "tool_result"; end
  end

  # Pipeline that injects pending_functions and optionally sets should_exit.
  class ShouldExitPipeline
    attr_reader :call_count

    def initialize(exit_on_call: nil)
      @exit_on_call = exit_on_call
      @call_count = 0
      @fn = LoopTestFunction.new(id: "call_1", name: "test_tool", arguments: "{}")
    end

    def call(env)
      @call_count += 1

      # Always give pending functions so the loop would continue.
      env[:pending_functions] = [@fn]

      if @exit_on_call && @call_count >= @exit_on_call
        env[:should_exit] = {
          reason:  "test_exit",
          message: "forced exit for test",
          source:  "ShouldExitPipeline",
        }
      end

      FakeResponse.new("response #{@call_count}")
    end
  end

  it "breaks the loop when should_exit is set on the initial call" do
    Sync do
      pipeline = ShouldExitPipeline.new(exit_on_call: 1)
      step = Brute::Loop::AgentTurn.new(
        agent: make_agent,
        session: Brute::Store::Session.new,
        pipeline: pipeline,
        input: "hi",
      )
      step.call(Async::Task.current)

      # Pipeline called once (initial call). The loop never entered
      # because should_exit was set before the while guard.
      pipeline.call_count.should == 1
      step.state.should == :completed
    end
  end

  it "breaks the loop mid-iteration when should_exit is set" do
    Sync do
      # exit_on_call: 2 means the first call returns tools (loop enters),
      # the second call (inside the loop) sets should_exit.
      pipeline = ShouldExitPipeline.new(exit_on_call: 2)
      step = Brute::Loop::AgentTurn.new(
        agent: make_agent,
        session: Brute::Store::Session.new,
        pipeline: pipeline,
        input: "hi",
      )
      step.call(Async::Task.current)

      # Two calls: initial + one loop iteration. The loop did not
      # continue to a third call because should_exit was set.
      pipeline.call_count.should == 2
      step.state.should == :completed
    end
  end

  it "loops normally when should_exit is not set" do
    Sync do
      call_count = 0
      fn = LoopTestFunction.new(id: "call_1", name: "test_tool", arguments: "{}")

      pipeline_obj = Object.new
      pipeline_obj.define_singleton_method(:call_count) { call_count }
      pipeline_obj.define_singleton_method(:call) do |env|
        call_count += 1
        if call_count <= 3
          env[:pending_functions] = [fn]
        else
          env[:pending_functions] = []
        end
        FakeResponse.new("response #{call_count}")
      end

      step = Brute::Loop::AgentTurn.new(
        agent: make_agent,
        session: Brute::Store::Session.new,
        pipeline: pipeline_obj,
        input: "hi",
      )
      step.call(Async::Task.current)

      # Call 1 (initial) → pending_functions has fn → loop enters
      # Loop iter 1: execute tools, call pipeline (call 2) → still has fn → continues
      # Loop iter 2: execute tools, call pipeline (call 3) → still has fn → continues
      # Loop iter 3: execute tools, call pipeline (call 4) → empty → exits
      call_count.should == 4
      step.state.should == :completed
    end
  end
end
