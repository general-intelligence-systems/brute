# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  # Bridges llm.rb's streaming callbacks to the host application.
  #
  # Text and reasoning chunks fire immediately as the LLM generates them.
  # Tool calls are collected but NOT executed — execution is deferred to the
  # orchestrator after the stream completes. This ensures text is never
  # concurrent with tool execution.
  #
  # After the stream finishes, the orchestrator reads +pending_tools+ to
  # dispatch all tool calls concurrently, then fires +on_tool_call_start+
  # once with the full batch.
  #
  class AgentStream < LLM::Stream
    # Tool call metadata recorded during streaming, used by ToolUseGuard
    # when ctx.functions is empty (nil-choice bug in llm.rb).
    attr_reader :pending_tool_calls

    # Deferred tool/error pairs: [(LLM::Function, error_or_nil), ...]
    # The orchestrator reads these after the stream completes.
    attr_reader :pending_tools

    def initialize(on_content: nil, on_reasoning: nil, on_question: nil)
      @on_content = on_content
      @on_reasoning = on_reasoning
      @on_question = on_question
      @pending_tool_calls = []
      @pending_tools = []
    end

    # The on_question callback, needed by the orchestrator to set
    # thread/fiber-locals before tool execution.
    attr_reader :on_question

    def on_content(text)
      @on_content&.call(text)
    end

    def on_reasoning_content(text)
      @on_reasoning&.call(text)
    end

    # Called by llm.rb per tool as it arrives during streaming.
    # Records only — no execution, no threads, no queue pushes.
    def on_tool_call(tool, error)
      @pending_tool_calls << { id: tool.id, name: tool.name, arguments: tool.arguments }
      @pending_tools << [tool, error]
    end

    # Clear only the tool call metadata (used by ToolUseGuard after it
    # has consumed the data for synthetic message injection).
    def clear_pending_tool_calls!
      @pending_tool_calls.clear
    end

    # Clear the deferred execution queue after the orchestrator has
    # consumed and dispatched all tool calls.
    def clear_pending_tools!
      @pending_tools.clear
    end
  end
end

if __FILE__ == $0
  require_relative "../../spec/spec_helper"

  RSpec.describe Brute::AgentStream do
    # Build a mock tool that quacks like LLM::Function.
    def mock_tool(id:, name:, arguments: {})
      instance_double(LLM::Function,
        id: id,
        name: name,
        arguments: arguments,
      )
    end

    describe "#on_tool_call" do
      it "records tool/error pair in pending_tools without spawning threads" do
        stream = described_class.new
        tool = mock_tool(id: "toolu_1", name: "read")

        stream.on_tool_call(tool, nil)

        expect(stream.pending_tools.size).to eq(1)
        recorded_tool, recorded_error = stream.pending_tools.first
        expect(recorded_tool).to eq(tool)
        expect(recorded_error).to be_nil
      end

      it "records error tools in pending_tools" do
        stream = described_class.new
        tool = mock_tool(id: "toolu_err", name: "bad_tool")
        error = LLM::Function::Return.new("toolu_err", "bad_tool", { error: true })

        stream.on_tool_call(tool, error)

        expect(stream.pending_tools.size).to eq(1)
        _, recorded_error = stream.pending_tools.first
        expect(recorded_error).to eq(error)
      end

      it "records pending tool call metadata for ToolUseGuard" do
        stream = described_class.new
        tool = mock_tool(
          id: "toolu_abc",
          name: "read",
          arguments: { "file_path" => "test.rb" },
        )

        stream.on_tool_call(tool, nil)

        calls = stream.pending_tool_calls
        expect(calls).not_to be_empty
        expect(calls.first).to include(
          id: "toolu_abc",
          name: "read",
          arguments: { "file_path" => "test.rb" },
        )
      end

      it "records metadata for multiple tool calls" do
        stream = described_class.new
        tool1 = mock_tool(id: "toolu_1", name: "read", arguments: { "file_path" => "a.rb" })
        tool2 = mock_tool(id: "toolu_2", name: "write", arguments: { "file_path" => "b.rb" })

        stream.on_tool_call(tool1, nil)
        stream.on_tool_call(tool2, nil)

        expect(stream.pending_tool_calls.size).to eq(2)
        expect(stream.pending_tool_calls.map { |c| c[:id] }).to eq(["toolu_1", "toolu_2"])

        expect(stream.pending_tools.size).to eq(2)
        expect(stream.pending_tools.map { |t, _| t }).to eq([tool1, tool2])
      end
    end

    describe "#clear_pending_tool_calls! and #clear_pending_tools!" do
      it "empties both pending_tool_calls and pending_tools" do
        stream = described_class.new
        tool = mock_tool(id: "toolu_1", name: "read")

        stream.on_tool_call(tool, nil)
        expect(stream.pending_tool_calls).not_to be_empty
        expect(stream.pending_tools).not_to be_empty

        stream.clear_pending_tool_calls!
        stream.clear_pending_tools!
        expect(stream.pending_tool_calls).to be_empty
        expect(stream.pending_tools).to be_empty
      end
    end

    describe "#on_content" do
      it "fires the content callback" do
        received = nil
        stream = described_class.new(on_content: ->(text) { received = text })

        stream.on_content("hello")

        expect(received).to eq("hello")
      end
    end

    describe "#on_reasoning_content" do
      it "fires the reasoning callback" do
        received = nil
        stream = described_class.new(on_reasoning: ->(text) { received = text })

        stream.on_reasoning_content("thinking...")

        expect(received).to eq("thinking...")
      end
    end
  end
end
