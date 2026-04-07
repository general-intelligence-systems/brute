# frozen_string_literal: true

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
    it "records tool/error pairs in pending_tools without spawning threads" do
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

    it "does not push anything to the queue" do
      stream = described_class.new
      tool = mock_tool(id: "toolu_1", name: "read")

      stream.on_tool_call(tool, nil)

      expect(stream.queue).to be_empty
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

  describe "#clear_pending!" do
    it "empties both pending_tool_calls and pending_tools" do
      stream = described_class.new
      tool = mock_tool(id: "toolu_1", name: "read")

      stream.on_tool_call(tool, nil)
      expect(stream.pending_tool_calls).not_to be_empty
      expect(stream.pending_tools).not_to be_empty

      stream.clear_pending!
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
