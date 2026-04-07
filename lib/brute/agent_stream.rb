# frozen_string_literal: true

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
