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

  it "sets empty pending_tools when nothing pending" do
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::PendingToolCollection
      run ->(_env) { MockResponse.new(content: "ok") }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    turn.env[:pending_tools].should == []
  end

  it "normalizes pending_functions into (fn, nil) pairs" do
    fn = Struct.new(:id, :name, :arguments, keyword_init: true)
           .new(id: "c1", name: "read", arguments: {})

    captured = nil
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::PendingToolCollection
      run ->(env) {
        env[:pending_functions] = [fn]
        response = MockResponse.new(content: "ok")
        # PendingToolCollection runs post-call, so we need to capture after
        response
      }
    end

    # PendingToolCollection collects from pending_functions post-call.
    # The LLMCall middleware normally sets pending_functions, so we simulate
    # by injecting them in the inner app.
    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    turn.env[:pending_tools].size.should == 1
    turn.env[:pending_tools][0][0].name.should == "read"
  end
end
