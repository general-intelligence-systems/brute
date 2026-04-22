# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Loop
  # Bridges llm.rb's streaming callbacks to the host application.
  #
  # Text and reasoning chunks fire immediately as the LLM generates them.
  # Tool calls are collected but NOT executed — execution is deferred to the
  # agent loop after the stream completes. This ensures text is never
  # concurrent with tool execution.
  #
  # After the stream finishes, the agent loop reads +pending_tools+ to
  # dispatch all tool calls concurrently, then fires +on_tool_call_start+
  # once with the full batch.
  #
  class AgentStream < LLM::Stream
    # Tool call metadata recorded during streaming, used by ToolUseGuard
    # when ctx.functions is empty (nil-choice bug in llm.rb).
    attr_reader :pending_tool_calls

    # Deferred tool/error pairs: [(LLM::Function, error_or_nil), ...]
    # The agent loop reads these after the stream completes.
    attr_reader :pending_tools

    def initialize(on_content: nil, on_reasoning: nil, on_question: nil)
      @on_content = on_content
      @on_reasoning = on_reasoning
      @on_question = on_question
      @pending_tool_calls = []
      @pending_tools = []
    end

    # The on_question callback, needed by the agent loop to set
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

    # Clear the deferred execution queue after the agent loop has
    # consumed and dispatched all tool calls.
    def clear_pending_tools!
      @pending_tools.clear
    end
  end
  end
end

test do
  FakeTool = Struct.new(:id, :name, :arguments, keyword_init: true)

  it "records tool in pending_tools" do
    stream = Brute::Loop::AgentStream.new
    tool = FakeTool.new(id: "toolu_1", name: "read", arguments: {})
    stream.on_tool_call(tool, nil)
    stream.pending_tools.size.should == 1
  end

  it "records tool call metadata" do
    stream = Brute::Loop::AgentStream.new
    tool = FakeTool.new(id: "toolu_abc", name: "read", arguments: { "file_path" => "test.rb" })
    stream.on_tool_call(tool, nil)
    stream.pending_tool_calls.first[:id].should == "toolu_abc"
  end

  it "records multiple tool calls" do
    stream = Brute::Loop::AgentStream.new
    t1 = FakeTool.new(id: "toolu_1", name: "read", arguments: {})
    t2 = FakeTool.new(id: "toolu_2", name: "write", arguments: {})
    stream.on_tool_call(t1, nil)
    stream.on_tool_call(t2, nil)
    stream.pending_tool_calls.size.should == 2
  end

  it "clears pending tool calls and tools" do
    stream = Brute::Loop::AgentStream.new
    tool = FakeTool.new(id: "toolu_1", name: "read", arguments: {})
    stream.on_tool_call(tool, nil)
    stream.clear_pending_tool_calls!
    stream.clear_pending_tools!
    stream.pending_tool_calls.should.be.empty
  end

  it "fires the content callback" do
    received = nil
    stream = Brute::Loop::AgentStream.new(on_content: ->(text) { received = text })
    stream.on_content("hello")
    received.should == "hello"
  end

  it "fires the reasoning callback" do
    received = nil
    stream = Brute::Loop::AgentStream.new(on_reasoning: ->(text) { received = text })
    stream.on_reasoning_content("thinking...")
    received.should == "thinking..."
  end
end
