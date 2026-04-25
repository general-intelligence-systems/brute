# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Executes question tool calls sequentially, with the on_question callback
    # available via Thread.current[:on_question].
    #
    # Runs POST-call. After PendingToolCollection normalizes pending tools into
    # env[:pending_tools], this middleware:
    #
    #   1. Partitions out tools where fn.name == "question"
    #   2. Fires on_tool_call_start for the question batch
    #   3. Executes each question sequentially (blocking, interactive)
    #   4. Fires on_tool_result per question
    #   5. Accumulates results into env[:tool_results_queue]
    #   6. Leaves non-question tools in env[:pending_tools] for ToolCall middleware
    #
    # Questions must run before parallel tools because they are interactive
    # and may block waiting for user input.
    #
    class Question < Base
      def call(env)
        response = @app.call(env)

        pending = env[:pending_tools]
        return response unless pending&.any?

        questions, others = pending.partition { |fn, _| fn.name == "question" }
        env[:pending_tools] = others
        return response unless questions.any?

        callbacks = env[:callbacks]

        # Fire on_tool_call_start with the question batch
        callbacks.on_tool_call_start(
          questions.map { |fn, _| { name: fn.name, call_id: fn.id, arguments: fn.arguments } }
        )

        env[:tool_results_queue] ||= []

        questions.each do |fn, err|
          if err
            callbacks.on_tool_result(err.name, result_value(err))
            env[:tool_results_queue] << err
          else
            Thread.current[:on_question] = callbacks.on_question
            result = fn.call
            callbacks.on_tool_result(fn.name, result_value(result))
            env[:tool_results_queue] << result
          end
        end

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

  it "is a no-op when no questions in pending tools" do
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::Question
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

  it "executes question tools and fires callbacks" do
    fn = Struct.new(:id, :name, :arguments, :return_value, keyword_init: true) do
      def call; self; end
      def value; return_value; end
    end.new(id: "q1", name: "question", arguments: { "text" => "hi" }, return_value: "answer")

    tool_results = []
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::Question
      run ->(env) {
        env[:pending_tools] = [[fn, nil]] if env[:pending_tools].empty?
        MockResponse.new(content: "ok")
      }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
      callbacks: { on_tool_result: ->(name, val) { tool_results << [name, val] } },
    )
    tool_results.any? { |name, _| name == "question" }.should.be.true
  end
end
