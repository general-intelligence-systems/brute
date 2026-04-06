# frozen_string_literal: true

RSpec.describe Brute::AgentStream do
  # Build a mock tool that quacks like LLM::Function.
  # LLM::Function#name is a dual getter/setter: name() returns the name,
  # name("x") sets it. We only need the getter form here.
  def mock_tool(id:, name:, arguments: {})
    tool = instance_double(LLM::Function,
      id: id,
      name: name,
      arguments: arguments,
    )
    # #call returns an LLM::Function::Return
    allow(tool).to receive(:call).and_return(
      LLM::Function::Return.new(id, name, { success: true })
    )
    tool
  end

  describe "#on_tool_call" do
    it "pushes a Task onto the queue for a valid tool" do
      stream = described_class.new
      tool = mock_tool(id: "toolu_1", name: "read")

      stream.on_tool_call(tool, nil)

      expect(stream.queue).not_to be_empty
    end

    it "pushes the error directly onto the queue for an errored tool" do
      stream = described_class.new
      tool = mock_tool(id: "toolu_err", name: "bad_tool")
      error = LLM::Function::Return.new("toolu_err", "bad_tool", { error: true })

      stream.on_tool_call(tool, error)

      expect(stream.queue).not_to be_empty
    end

    it "fires the on_tool_call callback with name and arguments" do
      received = nil
      stream = described_class.new(
        on_tool_call: ->(name, args) { received = { name: name, args: args } },
      )
      tool = mock_tool(id: "toolu_2", name: "write", arguments: { "file_path" => "f.rb" })

      stream.on_tool_call(tool, nil)

      expect(received).to eq({ name: "write", args: { "file_path" => "f.rb" } })
    end

    # ── Bug: stream does not track tool call metadata ─────────────────
    #
    # When the LLM responds with ONLY tool_use blocks (no text), llm.rb's
    # adapt_choices produces nil choices. The assistant message is never
    # stored, so ctx.functions is empty. The ToolUseGuard cannot inject a
    # synthetic assistant message because it relies on ctx.functions for
    # the tool IDs, names, and arguments.
    #
    # In streaming mode, AgentStream#on_tool_call receives the full tool
    # object (with id, name, arguments) before spawning the thread. It
    # should record this metadata so the ToolUseGuard (or orchestrator)
    # can retrieve it when ctx.functions is empty.
    #
    # This test will FAIL until AgentStream stores pending tool metadata.

    it "records pending tool call metadata for guard injection" do
      stream = described_class.new
      tool = mock_tool(
        id: "toolu_abc",
        name: "read",
        arguments: { "file_path" => "test.rb" },
      )

      stream.on_tool_call(tool, nil)

      expect(stream).to respond_to(:pending_tool_calls),
        "AgentStream must expose #pending_tool_calls so the ToolUseGuard " \
        "can inject a synthetic assistant message when ctx.functions is empty."

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

      expect(stream).to respond_to(:pending_tool_calls)

      calls = stream.pending_tool_calls
      expect(calls.size).to eq(2)
      expect(calls.map { |c| c[:id] }).to eq(["toolu_1", "toolu_2"])
    end
  end

  describe "#clear_pending_tool_calls!" do
    it "empties the pending_tool_calls array" do
      stream = described_class.new
      tool = mock_tool(id: "toolu_1", name: "read")

      stream.on_tool_call(tool, nil)
      expect(stream.pending_tool_calls).not_to be_empty

      stream.clear_pending_tool_calls!
      expect(stream.pending_tool_calls).to be_empty
    end
  end
end
