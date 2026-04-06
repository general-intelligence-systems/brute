# frozen_string_literal: true

# Regression test for the tool_use_id orphaning bug.
#
# When the LLM responds with ONLY tool_use blocks (no text), llm.rb's
# adapt_choices creates messages only from text blocks. No text = empty
# choices = res.choices[-1] is nil. The BufferNilGuard strips nil, so
# the assistant message carrying tool_use blocks is never stored.
#
# On the next ctx.talk(tool_results), the buffer has a tool_result
# referencing a tool_use_id that doesn't exist in any preceding assistant
# message. Anthropic rejects this with "unexpected tool_use_id".

RSpec.describe 'Context tool_use/tool_result pairing' do
  let(:provider) { MockProvider.new }

  context 'when LLM responds with text + tool_use' do
    it 'preserves assistant message in the buffer' do
      ctx = LLM::Context.new(provider, tools: [])

      response = MockResponse.new(
        content: 'Let me read that file',
        tool_calls: [{ id: 'toolu_123', name: 'read', arguments: { 'file_path' => 'test.rb' } }]
      )
      allow(provider).to receive(:complete).and_return(response)

      prompt = ctx.prompt do |p|
        p.system('You are a helper')
        p.user('Read test.rb')
      end
      ctx.talk(prompt)

      assistant_msg = ctx.messages.to_a.find { |m| m.role.to_s == 'assistant' }
      expect(assistant_msg).not_to be_nil
      expect(assistant_msg.tool_call?).to be true
    end
  end

  context "when LLM responds with ONLY tool_use (no text) -- THE BUG" do
    # These tests document the underlying llm.rb bug. The ToolUseGuard middleware
    # works around it at the pipeline level. These will pass when llm.rb is fixed.
    it "preserves assistant message even when choices[-1] is nil", pending: "llm.rb upstream bug -- ToolUseGuard middleware works around this" do
      ctx = LLM::Context.new(provider, tools: [])

      # Simulate what actually happens: choices is empty or choices[-1] is nil
      # This is what the Anthropic adapter produces for tool-only responses
      response = MockResponse.new(content: '')
      allow(response).to receive(:choices).and_return([nil])

      allow(provider).to receive(:complete).and_return(response)

      prompt = ctx.prompt do |p|
        p.system('You are a helper')
        p.user('Read test.rb')
      end
      ctx.talk(prompt)

      messages = ctx.messages.to_a

      # After the prompt (system + user), there should be an assistant message.
      # With the bug, nil gets filtered by BufferNilGuard and no assistant
      # message is stored.
      non_prompt_messages = messages.reject { |m| %w[system user].include?(m.role.to_s) }
      expect(non_prompt_messages).not_to be_empty,
                                         'Expected an assistant message in the buffer after talk(), ' \
                                         "but only found: #{messages.map { |m| m.role.to_s }.inspect}"
    end

    it "stores tool_use blocks so tool_result can reference them", pending: "llm.rb upstream bug -- ToolUseGuard middleware works around this" do
      ctx = LLM::Context.new(provider, tools: [])

      # First call: tool-only response (nil choice)
      tool_response = MockResponse.new(content: '')
      allow(tool_response).to receive(:choices).and_return([nil])

      # Second call: normal text response
      text_response = MockResponse.new(content: "Here's what I found")

      call_count = 0
      allow(provider).to receive(:complete) do |*_args|
        call_count += 1
        call_count == 1 ? tool_response : text_response
      end

      prompt = ctx.prompt do |p|
        p.system('You are a helper')
        p.user('Read test.rb')
      end
      ctx.talk(prompt)

      # The buffer must have an assistant message before we send tool_result.
      # Without it, the API gets: [user, user(tool_result)] which is invalid.
      messages_before = ctx.messages.to_a
      has_assistant = messages_before.any? { |m| m.role.to_s == 'assistant' }

      expect(has_assistant).to be(true),
                               'Buffer missing assistant message after tool-only response. ' \
                               "Messages: #{messages_before.map(&:role).inspect}. " \
                               "This causes 'unexpected tool_use_id' when tool_result is sent."
    end
  end
end
