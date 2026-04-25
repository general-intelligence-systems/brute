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

        callbacks = env[:callbacks] || {}

        # Fire on_tool_call_start with the question batch
        callbacks[:on_tool_call_start]&.call(
          questions.map { |fn, _| { name: fn.name, arguments: fn.arguments } }
        )

        env[:tool_results_queue] ||= []

        questions.each do |fn, err|
          if err
            callbacks[:on_tool_result]&.call(err.name, result_value(err))
            env[:tool_results_queue] << err
          else
            Thread.current[:on_question] = callbacks[:on_question]
            result = fn.call
            callbacks[:on_tool_result]&.call(fn.name, result_value(result))
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

  FakeFunc = Struct.new(:id, :name, :arguments, :return_value, keyword_init: true) do
    def call
      self
    end

    def value
      return_value
    end
  end

  FakeError = Struct.new(:name, :value, keyword_init: true)

  def build_env(**overrides)
    { provider: MockProvider.new, model: nil, input: "test prompt", tools: [],
      messages: [], stream: nil, params: {}, metadata: {}, callbacks: {},
      tool_results: nil, streaming: false, should_exit: nil,
      pending_functions: [], pending_tools: [], tool_results_queue: nil }.merge(overrides)
  end

  def make_middleware(app = nil)
    app ||= ->(_env) { MockResponse.new(content: "ok") }
    Brute::Middleware::Question.new(app)
  end

  it "is a no-op when no pending tools" do
    env = build_env(pending_tools: [])
    make_middleware.call(env)
    env[:tool_results_queue].should.be.nil
  end

  it "is a no-op when no questions in pending tools" do
    fn = FakeFunc.new(id: "c1", name: "fs_read", arguments: {}, return_value: "data")
    env = build_env(pending_tools: [[fn, nil]])
    make_middleware.call(env)
    env[:tool_results_queue].should.be.nil
  end

  it "executes question tools and accumulates results" do
    fn = FakeFunc.new(id: "q1", name: "question", arguments: {}, return_value: "answer")
    env = build_env(pending_tools: [[fn, nil]])
    make_middleware.call(env)
    env[:tool_results_queue].size.should == 1
  end

  it "removes questions from pending_tools" do
    q = FakeFunc.new(id: "q1", name: "question", arguments: {}, return_value: "answer")
    t = FakeFunc.new(id: "c1", name: "fs_read", arguments: {}, return_value: "data")
    env = build_env(pending_tools: [[q, nil], [t, nil]])
    make_middleware.call(env)
    env[:pending_tools].size.should == 1
    env[:pending_tools][0][0].name.should == "fs_read"
  end

  it "handles pre-existing errors" do
    fn = FakeFunc.new(id: "q1", name: "question", arguments: {}, return_value: nil)
    err = FakeError.new(name: "question", value: { error: true })
    env = build_env(pending_tools: [[fn, err]])
    make_middleware.call(env)
    env[:tool_results_queue].size.should == 1
    env[:tool_results_queue][0].should == err
  end

  it "fires on_tool_call_start callback" do
    received = nil
    callbacks = { on_tool_call_start: ->(batch) { received = batch } }
    fn = FakeFunc.new(id: "q1", name: "question", arguments: { "text" => "hi" }, return_value: "ok")
    env = build_env(pending_tools: [[fn, nil]], callbacks: callbacks)
    make_middleware.call(env)
    received.size.should == 1
    received[0][:name].should == "question"
  end

  it "fires on_tool_result callback per question" do
    results = []
    callbacks = { on_tool_result: ->(name, val) { results << [name, val] } }
    fn = FakeFunc.new(id: "q1", name: "question", arguments: {}, return_value: "answer")
    env = build_env(pending_tools: [[fn, nil]], callbacks: callbacks)
    make_middleware.call(env)
    results.size.should == 1
    results[0][0].should == "question"
  end

  it "sets Thread.current[:on_question] before calling" do
    captured = nil
    on_q = ->(q, queue) { queue << "reply" }
    fn_call = -> {
      captured = Thread.current[:on_question]
      FakeFunc.new(id: "q1", name: "question", arguments: {}, return_value: "ok")
    }
    callable = Object.new
    callable.define_singleton_method(:id) { "q1" }
    callable.define_singleton_method(:name) { "question" }
    callable.define_singleton_method(:arguments) { {} }
    callable.define_singleton_method(:call) { captured = Thread.current[:on_question]; self }
    callable.define_singleton_method(:value) { "ok" }
    callbacks = { on_question: on_q }
    env = build_env(pending_tools: [[callable, nil]], callbacks: callbacks)
    make_middleware.call(env)
    captured.should == on_q
  end
end
