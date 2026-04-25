# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Normalizes pending tool calls from two possible sources into a single
    # canonical format in env[:pending_tools].
    #
    # Runs POST-call. After the LLM call completes, tool calls can arrive via:
    #
    #   1. Streaming mode: env[:stream].pending_tools — already paired as
    #      [(LLM::Function, error_or_nil), ...] because the stream can detect
    #      invalid tool calls during delivery.
    #
    #   2. Non-streaming mode: env[:pending_functions] — a flat Array of
    #      LLM::Function objects set by LLMCall.
    #
    # This middleware reads whichever source has data, normalizes into
    # [(function, error_or_nil), ...] pairs in env[:pending_tools], and
    # clears the source so downstream middleware never has to care about
    # which mode produced the tool calls.
    #
    class PendingToolCollection < Base
      def call(env)
        response = @app.call(env)

        stream = env[:stream]

        env[:pending_tools] = if stream&.pending_tools&.any?
          stream.pending_tools.dup.tap { stream.clear_pending_tools! }
        elsif env[:pending_functions]&.any?
          env[:pending_functions].dup.tap { env[:pending_functions] = [] }.map { |fn| [fn, nil] }
        else
          []
        end

        response
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
      tool_results: nil, streaming: false, should_exit: nil, pending_functions: [] }.merge(overrides)
  end

  def make_middleware(app = nil)
    app ||= ->(_env) { MockResponse.new(content: "ok") }
    Brute::Middleware::PendingToolCollection.new(app)
  end

  FakeFunc = Struct.new(:id, :name, :arguments, keyword_init: true)

  # Minimal stream double
  class FakeStream
    attr_reader :pending_tools

    def initialize(tools = [])
      @pending_tools = tools
      @cleared = false
    end

    def clear_pending_tools!
      @pending_tools = []
      @cleared = true
    end

    def cleared? = @cleared
  end

  it "sets empty pending_tools when nothing pending" do
    env = build_env
    make_middleware.call(env)
    env[:pending_tools].should == []
  end

  it "normalizes pending_functions into (fn, nil) pairs" do
    fn1 = FakeFunc.new(id: "c1", name: "read", arguments: {})
    fn2 = FakeFunc.new(id: "c2", name: "write", arguments: {})
    env = build_env(pending_functions: [fn1, fn2])
    make_middleware.call(env)
    env[:pending_tools].size.should == 2
    env[:pending_tools][0].should == [fn1, nil]
    env[:pending_tools][1].should == [fn2, nil]
  end

  it "clears pending_functions after consumption" do
    fn = FakeFunc.new(id: "c1", name: "read", arguments: {})
    env = build_env(pending_functions: [fn])
    make_middleware.call(env)
    env[:pending_functions].should == []
  end

  it "prefers stream pending_tools over pending_functions" do
    fn_stream = FakeFunc.new(id: "s1", name: "stream_tool", arguments: {})
    fn_env = FakeFunc.new(id: "e1", name: "env_tool", arguments: {})
    stream = FakeStream.new([[fn_stream, nil]])
    env = build_env(stream: stream, pending_functions: [fn_env])
    make_middleware.call(env)
    env[:pending_tools].size.should == 1
    env[:pending_tools][0][0].name.should == "stream_tool"
  end

  it "clears stream pending_tools after consumption" do
    fn = FakeFunc.new(id: "s1", name: "tool", arguments: {})
    stream = FakeStream.new([[fn, nil]])
    env = build_env(stream: stream)
    make_middleware.call(env)
    stream.should.be.cleared
  end

  it "preserves error pairs from stream" do
    fn = FakeFunc.new(id: "s1", name: "bad_tool", arguments: {})
    error = Struct.new(:name, :value).new("bad_tool", { error: true })
    stream = FakeStream.new([[fn, error]])
    env = build_env(stream: stream)
    make_middleware.call(env)
    env[:pending_tools][0][1].should == error
  end
end
