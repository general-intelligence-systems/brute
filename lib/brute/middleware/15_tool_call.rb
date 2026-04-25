# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Executes non-question tool calls in parallel via the agent turn's
    # ParallelQueue.
    #
    # Runs POST-call. After Question middleware has extracted question tools,
    # this middleware processes whatever remains in env[:pending_tools]:
    #
    #   1. Fires on_tool_call_start for the batch
    #   2. Separates pre-existing errors from executable functions
    #   3. Wraps executables in ToolCallStep, dispatches to ParallelQueue
    #   4. Drains the queue
    #   5. Fires on_tool_result per tool
    #   6. Accumulates results into env[:tool_results_queue]
    #   7. Resets the sub-queue for the next iteration
    #
    # Requires env[:turn] to be the AgentTurn step instance (provides the
    # sub-queue via #jobs and cleanup via #reset_jobs!).
    #
    class ToolCall < Base
      def call(env)
        response = @app.call(env)

        pending = env[:pending_tools]
        return response unless pending&.any?

        callbacks = env[:callbacks]
        turn = env[:turn]

        # Fire on_tool_call_start with the remaining (non-question) batch
        callbacks.on_tool_call_start(
          pending.map { |fn, _| { name: fn.name, call_id: fn.id, arguments: fn.arguments } }
        )

        env[:tool_results_queue] ||= []

        errors, executable = pending.partition { |_, err| err }

        # Record pre-existing errors (from stream's on_tool_call)
        errors.each do |_, err|
          callbacks.on_tool_result(err.name, result_value(err))
          env[:tool_results_queue] << err
        end

        if executable.any?
          tool_steps = executable.map { |fn, _| Brute::Loop::ToolCallStep.new(function: fn) }
          tool_steps.each { |s| turn.jobs(type: Brute::Queue::ParallelQueue) << s }
          turn.jobs(type: Brute::Queue::ParallelQueue).drain

          tool_steps.each do |s|
            val = s.state == :completed ? s.result : s.error
            callbacks.on_tool_result(s.function.name, result_value(val))
            env[:tool_results_queue] << val
          end
        end

        # Clear pending and reset sub-queue for the next iteration
        env[:pending_tools] = []
        turn.reset_jobs!

        response
      end

      private

      def result_value(result)
        result.respond_to?(:value) ? result.value : result
      end
    end
  end
end

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  FakeFunc = Struct.new(:id, :name, :arguments, :return_value, keyword_init: true) do
    def call
      self
    end

    def value
      return_value
    end
  end

  FakeError = Struct.new(:name, :value, keyword_init: true)

  # Minimal turn double that provides a drainable queue
  class FakeTurn
    attr_reader :reset_called

    def initialize
      @queue = nil
      @reset_called = false
    end

    def jobs(type: nil)
      @queue ||= FakeQueue.new
    end

    def reset_jobs!
      @queue = nil
      @reset_called = true
    end
  end

  class FakeQueue
    attr_reader :steps

    def initialize
      @steps = []
    end

    def <<(step)
      @steps << step
    end

    def drain
      Sync do
        @steps.each { |s| s.call(Async::Task.current) }
      end
    end
  end

  def build_env(turn: FakeTurn.new, **overrides)
    { provider: MockProvider.new, model: nil, input: "test prompt", tools: [],
      messages: [], stream: nil, params: {}, metadata: {}, callbacks: {},
      tool_results: nil, streaming: false, should_exit: nil,
      pending_functions: [], pending_tools: [], tool_results_queue: nil,
      turn: turn }.merge(overrides)
  end

  def make_middleware(app = nil)
    app ||= ->(_env) { MockResponse.new(content: "ok") }
    Brute::Middleware::ToolCall.new(app)
  end

  it "is a no-op when no pending tools" do
    env = build_env(pending_tools: [])
    make_middleware.call(env)
    env[:tool_results_queue].should.be.nil
  end

  it "executes tools and accumulates results" do
    fn = FakeFunc.new(id: "c1", name: "fs_read", arguments: {}, return_value: "file data")
    env = build_env(pending_tools: [[fn, nil]])
    make_middleware.call(env)
    env[:tool_results_queue].size.should == 1
  end

  it "handles pre-existing errors" do
    fn = FakeFunc.new(id: "c1", name: "bad_tool", arguments: {}, return_value: nil)
    err = FakeError.new(name: "bad_tool", value: { error: true })
    env = build_env(pending_tools: [[fn, err]])
    make_middleware.call(env)
    env[:tool_results_queue].size.should == 1
    env[:tool_results_queue][0].should == err
  end

  it "clears pending_tools after processing" do
    fn = FakeFunc.new(id: "c1", name: "fs_read", arguments: {}, return_value: "ok")
    env = build_env(pending_tools: [[fn, nil]])
    make_middleware.call(env)
    env[:pending_tools].should == []
  end

  it "resets the turn sub-queue" do
    turn = FakeTurn.new
    fn = FakeFunc.new(id: "c1", name: "fs_read", arguments: {}, return_value: "ok")
    env = build_env(turn: turn, pending_tools: [[fn, nil]])
    make_middleware.call(env)
    turn.reset_called.should.be.true
  end

  it "fires on_tool_call_start callback" do
    received = nil
    callbacks = { on_tool_call_start: ->(batch) { received = batch } }
    fn = FakeFunc.new(id: "c1", name: "fs_read", arguments: { "path" => "x.rb" }, return_value: "ok")
    env = build_env(pending_tools: [[fn, nil]], callbacks: callbacks)
    make_middleware.call(env)
    received.size.should == 1
    received[0][:name].should == "fs_read"
  end

  it "fires on_tool_result callback per tool" do
    results = []
    callbacks = { on_tool_result: ->(name, val) { results << [name, val] } }
    fn = FakeFunc.new(id: "c1", name: "fs_read", arguments: {}, return_value: "data")
    env = build_env(pending_tools: [[fn, nil]], callbacks: callbacks)
    make_middleware.call(env)
    results.size.should == 1
    results[0][0].should == "fs_read"
  end

  it "handles mix of errors and executable" do
    fn_ok = FakeFunc.new(id: "c1", name: "fs_read", arguments: {}, return_value: "data")
    fn_bad = FakeFunc.new(id: "c2", name: "bad", arguments: {}, return_value: nil)
    err = FakeError.new(name: "bad", value: { error: true })
    env = build_env(pending_tools: [[fn_bad, err], [fn_ok, nil]])
    make_middleware.call(env)
    env[:tool_results_queue].size.should == 2
  end
end
