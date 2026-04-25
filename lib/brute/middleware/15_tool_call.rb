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

  it "is a no-op when no pending tools" do
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::ToolCall
      run ->(_env) { MockResponse.new(content: "ok") }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    turn.env[:tool_results_queue].should.be.nil
  end

  it "executes pending tools and queues results" do
    tool_start_batches = []
    tool_results = []
    injected = false

    fn = Struct.new(:id, :name, :arguments, :return_value, keyword_init: true) do
      def call; self; end
      def value; return_value; end
    end.new(id: "c1", name: "fs_read", arguments: { "path" => "x.rb" }, return_value: "file data")

    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::ToolResultPrep
      use Brute::Middleware::ToolCall
      run ->(env) {
        unless injected
          env[:pending_tools] = [[fn, nil]]
          injected = true
        end
        MockResponse.new(content: "ok")
      }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
      callbacks: {
        on_tool_call_start: ->(batch) { tool_start_batches << batch },
        on_tool_result: ->(name, val) { tool_results << [name, val] },
      },
    )
    tool_start_batches.flatten.any? { |tc| tc[:name] == "fs_read" }.should.be.true
    tool_results.any? { |name, _| name == "fs_read" }.should.be.true
  end
end
