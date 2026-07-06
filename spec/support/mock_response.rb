# frozen_string_literal: true

# A mock response satisfying a completion-response interface.
class MockResponse
  attr_reader :content, :choices, :usage

  def initialize(content: '', choices: nil, usage: nil, tool_calls: nil)
    @content = content
    @usage = usage || { input: 100, output: 50, reasoning: 0 }

    if choices
      @choices = choices
    elsif tool_calls
      # Simulate a tool-only response (no text, only tool calls)
      calls = tool_calls.map do |tc|
        Brute::ToolCall.new(id: tc[:id], name: tc[:name], arguments: tc[:arguments])
      end
      @choices = [Brute::Message.new(role: :assistant, content: content, tool_calls: calls)]
    else
      @choices = [Brute::Message.new(role: :assistant, content: content)]
    end
  end
end
