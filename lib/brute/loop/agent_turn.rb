# frozen_string_literal: true

require "bundler/setup"
require "brute"

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
        provider = agent.provider

        step_class = if provider
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

        step_class.new(
          agent:,
          session:,
          pipeline:,
          input:,
          callbacks:,
          **rest
        )
      end

      # Build, execute inside a Sync block, return the finished step.
      def self.perform(**)
        self.new(**).tap do |step|
          Sync do
            step.call(Async::Task.current)
          end
        end
      end

      require_relative "agent_turn/base"
      require_relative "agent_turn/anthropic"
      require_relative "agent_turn/open_ai"
      require_relative "agent_turn/google"
      require_relative "agent_turn/ollama"
    end
  end
end

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  class RecordingStack
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

  it "returns Base instance for unknown provider" do
    step = Brute::Loop::AgentTurn.new(
      agent: make_agent,
      session: Brute::Store::Session.new,
      pipeline: RecordingStack.new(responses: []),
      input: "hi",
    )
    step.should.be.kind_of Brute::Loop::AgentTurn::Base
  end

  it "calls the stack" do
    Sync do
      pipeline = RecordingStack.new(responses: [FakeResponse.new("hello")])
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
      pipeline = RecordingStack.new(responses: [FakeResponse.new("world")])
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
      pipeline = RecordingStack.new(responses: [FakeResponse.new("ok")])
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

  it "perform returns a completed step" do
    pipeline = RecordingStack.new(responses: [FakeResponse.new("done")])
    step = Brute::Loop::AgentTurn.perform(
      agent: make_agent,
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    step.state.should == :completed
  end

  it "is cancellable when pending" do
    step = Brute::Loop::AgentTurn.new(
      agent: Brute::Agent.new(provider: nil, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: RecordingStack.new(responses: []),
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
      pipeline = RecordingStack.new(responses: [FakeResponse.new("ok")])
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

  # A mock function that satisfies ToolCallStep's interface.
  LoopTestFunction = Struct.new(:id, :name, :arguments, keyword_init: true) do
    def call; self; end
    def value; "tool_result"; end
  end

  # Stack that injects pending_tools and optionally sets should_exit.
  class ShouldExitStack
    attr_reader :call_count

    def initialize(exit_on_call: nil)
      @exit_on_call = exit_on_call
      @call_count = 0
      @fn = LoopTestFunction.new(id: "call_1", name: "test_tool", arguments: "{}")
    end

    def call(env)
      @call_count += 1

      # Always give pending tools so the loop would continue.
      env[:pending_tools] = [[@fn, nil]]

      if @exit_on_call && @call_count >= @exit_on_call
        env[:should_exit] = {
          reason:  "test_exit",
          message: "forced exit for test",
          source:  "ShouldExitStack",
        }
      end

      FakeResponse.new("response #{@call_count}")
    end
  end

  it "breaks the loop when should_exit is set on the initial call" do
    Sync do
      stack = ShouldExitStack.new(exit_on_call: 1)
      step = Brute::Loop::AgentTurn.new(
        agent: make_agent,
        session: Brute::Store::Session.new,
        pipeline: stack,
        input: "hi",
      )
      step.call(Async::Task.current)

      # Stack called once (initial call). The loop never entered
      # because should_exit was set before the while guard.
      stack.call_count.should == 1
      step.state.should == :completed
    end
  end

  it "breaks the loop mid-iteration when should_exit is set" do
    Sync do
      # exit_on_call: 2 means the first call returns tools (loop enters),
      # the second call (inside the loop) sets should_exit.
      stack = ShouldExitStack.new(exit_on_call: 2)
      step = Brute::Loop::AgentTurn.new(
        agent: make_agent,
        session: Brute::Store::Session.new,
        pipeline: stack,
        input: "hi",
      )
      step.call(Async::Task.current)

      # Two calls: initial + one loop iteration. The loop did not
      # continue to a third call because should_exit was set.
      stack.call_count.should == 2
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
          env[:pending_tools] = [[fn, nil]]
        else
          env[:pending_tools] = []
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

      # Call 1 (initial) → pending_tools has fn → loop enters
      # Loop iter 1: call pipeline (call 2) → still has fn → continues
      # Loop iter 2: call pipeline (call 3) → still has fn → continues
      # Loop iter 3: call pipeline (call 4) → empty → exits
      call_count.should == 4
      step.state.should == :completed
    end
  end
end
