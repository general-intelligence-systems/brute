# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Guards against tool-only LLM responses where the assistant message
    # is dropped from the context buffer.
    #
    # When the LLM responds with only tool_use blocks (no text), llm.rb's
    # response adapter produces empty choices. The assistant message carrying
    # tool_use blocks may be lost. This causes "unexpected tool_use_id" on
    # the next call because tool_result references a tool_use that's missing
    # from the message history.
    #
    # This middleware runs post-call and ensures every pending tool_use ID
    # is covered by an assistant message in env[:messages]. It handles three
    # cases:
    #
    #   1. pending_functions is non-empty and the assistant message exists → no-op
    #   2. pending_functions is non-empty but the assistant message is missing
    #      (or has different IDs) → inject synthetic message
    #   3. pending_functions is empty (nil-choice bug) but the stream recorded
    #      tool calls → inject synthetic message using stream metadata
    #
    class ToolUseGuard
      def initialize(app)
        @app = app
      end

      def call(env)
        response = @app.call(env)

        # Collect pending tool data from env[:pending_functions] (primary)
        # or the stream's recorded metadata (fallback for nil-choice bug).
        tool_data = collect_tool_data(env)
        return response if tool_data.empty?

        # Find all tool_use IDs already covered by assistant messages.
        covered_ids = covered_tool_ids(env[:messages])

        # Inject a synthetic assistant message for any uncovered tool calls.
        uncovered = tool_data.reject { |td| covered_ids.include?(td[:id]) }
        inject_synthetic!(env[:messages], uncovered) unless uncovered.empty?

        response
      end

      private

      def collect_tool_data(env)
        functions = env[:pending_functions]
        if functions && !functions.empty?
          functions.map { |fn| { id: fn.id, name: fn.name, arguments: fn.arguments } }
        elsif env[:streaming]
          stream = env[:stream]
          if stream&.respond_to?(:pending_tool_calls)
            data = stream.pending_tool_calls.dup
            stream.clear_pending_tool_calls!
            data
          else
            []
          end
        else
          []
        end
      end

      def covered_tool_ids(messages)
        messages
          .select { |m| m.role.to_s == "assistant" && m.tool_call? }
          .flat_map { |m| (m.extra.original_tool_calls || []).map { |tc| tc["id"] } }
          .to_set
      end

      def inject_synthetic!(messages, uncovered)
        tool_calls = uncovered.map do |td|
          LLM::Object.from(id: td[:id], name: td[:name], arguments: td[:arguments])
        end
        original_tool_calls = uncovered.map do |td|
          { "type" => "tool_use", "id" => td[:id], "name" => td[:name], "input" => td[:arguments] || {} }
        end

        synthetic = LLM::Message.new(:assistant, "", {
          tool_calls: tool_calls,
          original_tool_calls: original_tool_calls,
        })
        messages << synthetic
      end
    end
  end
end

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  it "passes the response through when no pending functions" do
    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::ToolUseGuard
      run ->(_env) { MockResponse.new(content: "no tools") }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    turn.result.content.should == "no tools"
  end

  it "injects synthetic assistant message for uncovered tool calls" do
    fn = Struct.new(:id, :name, :arguments, keyword_init: true)
           .new(id: "toolu_1", name: "fs_read", arguments: { "path" => "test.rb" })

    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::ToolUseGuard
      run ->(env) {
        env[:pending_functions] = [fn]
        MockResponse.new(content: "")
      }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
    turn.env[:messages].any? { |m| m.role.to_s == "assistant" && m.tool_call? }.should.be.true
  end
end
