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

  def build_env(**overrides)
    { provider: MockProvider.new, model: nil, input: "test prompt", tools: [],
      messages: [], stream: nil, params: {}, metadata: {}, callbacks: {},
      tool_results: nil, streaming: false, should_exit: nil, pending_functions: [],
      tool_results_queue: nil }.merge(overrides)
  end

  def make_middleware(app = nil)
    app ||= ->(_env) { MockResponse.new(content: "ok") }
    Brute::Middleware::ToolResultPrep.new(app)
  end

  FakeReturn = Struct.new(:id, :name, :value)

  it "is a no-op on the first call (no queue, no iterations)" do
    env = build_env
    make_middleware.call(env)
    env[:input].should == "test prompt"
    env[:tool_results].should.be.nil
  end

  it "sets env[:input] from tool_results_queue" do
    r = FakeReturn.new("call_1", "fs_read", "file contents")
    env = build_env(tool_results_queue: [r])
    make_middleware.call(env)
    env[:input].should == [r]
  end

  it "formats env[:tool_results] as name-value pairs" do
    r = FakeReturn.new("call_1", "fs_read", "file contents")
    env = build_env(tool_results_queue: [r])
    make_middleware.call(env)
    env[:tool_results].should == [["fs_read", "file contents"]]
  end

  it "clears the queue after consumption" do
    r = FakeReturn.new("call_1", "fs_read", "data")
    env = build_env(tool_results_queue: [r])
    make_middleware.call(env)
    env[:tool_results_queue].should.be.nil
  end

  it "handles results without name/value methods" do
    result = { error: true, message: "boom" }
    env = build_env(tool_results_queue: [result])
    make_middleware.call(env)
    env[:tool_results].should == [["unknown", { error: true, message: "boom" }]]
  end

  it "is a no-op when queue is nil" do
    env = build_env(tool_results_queue: nil)
    make_middleware.call(env)
    env[:input].should == "test prompt"
    env[:tool_results].should.be.nil
  end

  it "is a no-op when queue is empty" do
    env = build_env(tool_results_queue: [])
    make_middleware.call(env)
    env[:input].should == "test prompt"
    env[:tool_results].should.be.nil
  end
end
