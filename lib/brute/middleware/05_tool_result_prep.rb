# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Transforms accumulated tool results from the previous iteration into
    # the format expected by the LLM call: env[:input] and env[:tool_results].
    #
    # Runs PRE-call. On the first pipeline call there is nothing to prep
    # (env[:tool_results_queue] is nil/empty), so this is a no-op. On
    # subsequent calls it:
    #
    #   1. Reads env[:tool_results_queue] (populated by Question/ToolCall middleware)
    #   2. Sets env[:input] to the raw results (fed back to the LLM)
    #   3. Sets env[:tool_results] to [[name, value], ...] for other middleware
    #   4. Clears env[:tool_results_queue]
    #
    class ToolResultPrep < Base
      def call(env)
        queue = env[:tool_results_queue]

        if queue&.any?
          env[:input] = queue
          env[:tool_results] = queue.filter_map { |r|
            name = r.respond_to?(:name) ? r.name : "unknown"
            value = r.respond_to?(:value) ? r.value : r
            [name, value]
          }
          env[:tool_results_queue] = nil
        end

        @app.call(env)
      end
    end
  end
end

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  it "is a no-op on the first call" do
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::ToolResultPrep
      run ->(_env) { MockResponse.new(content: "ok") }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    turn.env[:tool_results].should.be.nil
  end

  it "consumes tool_results_queue into tool_results on subsequent calls" do
    captured_tool_results = nil
    call_count = 0

    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::ToolResultPrep
      run ->(env) {
        call_count += 1
        if call_count == 1
          # First call: simulate tool execution by queuing results
          fake = Struct.new(:id, :name, :value).new("c1", "fs_read", "data")
          env[:tool_results_queue] = [fake]
        else
          captured_tool_results = env[:tool_results]
        end
        MockResponse.new(content: "ok")
      }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    captured_tool_results.should == [["fs_read", "data"]]
  end
end
