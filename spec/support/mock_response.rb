# frozen_string_literal: true

# A mock response satisfying llm.rb's response interface.
class MockResponse
  attr_reader :content, :choices, :usage

  def initialize(content: '', choices: nil, usage: nil, tool_calls: nil)
    @content = content
    @usage = usage || LLM::Usage.new(
      input_tokens: 100,
      output_tokens: 50,
      reasoning_tokens: 0,
      total_tokens: 150
    )

    if choices
      @choices = choices
    elsif tool_calls
      # Simulate a tool-only response (no text, only tool_use)
      extra = {
        tool_calls: tool_calls.map do |tc|
          LLM::Object.from(id: tc[:id], name: tc[:name], arguments: tc[:arguments])
        end,
        original_tool_calls: tool_calls.map do |tc|
          { 'type' => 'tool_use', 'id' => tc[:id], 'name' => tc[:name], 'input' => tc[:arguments] }
        end,
        usage: @usage
      }
      @choices = [LLM::Message.new(:assistant, content, extra)]
    else
      @choices = [LLM::Message.new(:assistant, content, { usage: @usage })]
    end
  end
end
