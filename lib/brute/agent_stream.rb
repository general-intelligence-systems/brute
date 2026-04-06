# frozen_string_literal: true

module Brute
  # Bridges llm.rb's streaming callbacks to forge-rb's callback system.
  #
  # Text and reasoning chunks fire immediately as the LLM generates them.
  # Tool calls spawn threads on arrival — tools start running while the
  # response is still streaming. on_tool_result fires as each thread finishes.
  #
  class AgentStream < LLM::Stream
    # Tool call metadata recorded during streaming, used by ToolUseGuard
    # when ctx.functions is empty (nil-choice bug in llm.rb).
    # Cleared by the guard after consumption to prevent stale data from
    # causing duplicate synthetic assistant messages on subsequent calls.
    attr_reader :pending_tool_calls

    def clear_pending_tool_calls!
      @pending_tool_calls.clear
    end

    def initialize(on_content: nil, on_reasoning: nil, on_tool_call: nil, on_tool_result: nil)
      @on_content = on_content
      @on_reasoning = on_reasoning
      @on_tool_call = on_tool_call
      @on_tool_result = on_tool_result
      @pending_tool_calls = []
    end

    def on_content(text)
      @on_content&.call(text)
    end

    def on_reasoning_content(text)
      @on_reasoning&.call(text)
    end

    def on_tool_call(tool, error)
      @pending_tool_calls << { id: tool.id, name: tool.name, arguments: tool.arguments }
      @on_tool_call&.call(tool.name, tool.arguments)

      if error
        queue << error
        @on_tool_result&.call(tool.name, error.value)
      else
        queue << LLM::Function::Task.new(spawn_with_callback(tool))
      end
    end

    private

    def spawn_with_callback(tool)
      on_result = @on_tool_result
      name = tool.name
      Thread.new do
        result = tool.call
        on_result&.call(name, result.respond_to?(:value) ? result.value : result)
        result
      end
    end
  end
end
