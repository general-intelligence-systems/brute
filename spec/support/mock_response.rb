# frozen_string_literal: true

# A mock response satisfying ruby_llm's response interface.
class MockResponse
  attr_reader :content, :choices, :usage

  def initialize(content: '', choices: nil, usage: nil, tool_calls: nil)
    @content = content
    @usage = usage || RubyLLM::Tokens.new(
      input: 100,
      output: 50,
      reasoning: 0,
    )

    if choices
      @choices = choices
    elsif tool_calls
      # Simulate a tool-only response (no text, only tool_use)
      tc_hash = tool_calls.each_with_object({}) do |tc, h|
        h[tc[:id]] = RubyLLM::ToolCall.new(id: tc[:id], name: tc[:name], arguments: tc[:arguments])
      end
      @choices = [RubyLLM::Message.new(role: :assistant, content: content, tool_calls: tc_hash)]
    else
      @choices = [RubyLLM::Message.new(role: :assistant, content: content)]
    end
  end
end
