# frozen_string_literal: true

require "tmpdir"

RSpec.describe Brute::MessageStore do
  let(:tmpdir) { Dir.mktmpdir("brute_test_") }
  let(:session_id) { "test-session-123" }
  let(:store) { described_class.new(session_id: session_id, dir: tmpdir) }

  after { FileUtils.rm_rf(tmpdir) }

  describe "#append_user" do
    it "creates a user message with text part" do
      id = store.append_user(text: "Hello")

      msg = store.message(id)
      expect(msg[:info][:role]).to eq("user")
      expect(msg[:info][:sessionID]).to eq(session_id)
      expect(msg[:parts].size).to eq(1)
      expect(msg[:parts][0][:type]).to eq("text")
      expect(msg[:parts][0][:text]).to eq("Hello")
    end

    it "generates sequential message IDs" do
      id1 = store.append_user(text: "First")
      id2 = store.append_user(text: "Second")

      expect(id1).to eq("msg_0001")
      expect(id2).to eq("msg_0002")
    end

    it "persists to disk as JSON" do
      id = store.append_user(text: "Persisted")

      path = File.join(tmpdir, "#{id}.json")
      expect(File.exist?(path)).to be true

      data = JSON.parse(File.read(path), symbolize_names: true)
      expect(data[:info][:role]).to eq("user")
      expect(data[:parts][0][:text]).to eq("Persisted")
    end
  end

  describe "#append_assistant" do
    it "creates an assistant message" do
      user_id = store.append_user(text: "Hi")
      asst_id = store.append_assistant(parent_id: user_id, model_id: "claude", provider_id: "anthropic")

      msg = store.message(asst_id)
      expect(msg[:info][:role]).to eq("assistant")
      expect(msg[:info][:parentID]).to eq(user_id)
      expect(msg[:info][:modelID]).to eq("claude")
      expect(msg[:info][:providerID]).to eq("anthropic")
      expect(msg[:info][:tokens]).to include(input: 0, output: 0)
      expect(msg[:parts]).to be_empty
    end
  end

  describe "#add_text_part" do
    it "appends a text part to an existing message" do
      asst_id = store.append_assistant

      store.add_text_part(message_id: asst_id, text: "Here is my response")

      msg = store.message(asst_id)
      expect(msg[:parts].size).to eq(1)
      expect(msg[:parts][0][:type]).to eq("text")
      expect(msg[:parts][0][:text]).to eq("Here is my response")
    end
  end

  describe "#add_tool_part / #complete_tool_part / #error_tool_part" do
    it "tracks tool lifecycle: running → completed" do
      asst_id = store.append_assistant

      store.add_tool_part(
        message_id: asst_id,
        tool: "read",
        call_id: "call_001",
        input: { file_path: "/tmp/test.rb" },
      )

      msg = store.message(asst_id)
      tool_part = msg[:parts].find { |p| p[:type] == "tool" }
      expect(tool_part[:tool]).to eq("read")
      expect(tool_part[:state][:status]).to eq("running")

      store.complete_tool_part(
        message_id: asst_id,
        call_id: "call_001",
        output: "file contents here",
      )

      msg = store.message(asst_id)
      tool_part = msg[:parts].find { |p| p[:type] == "tool" }
      expect(tool_part[:state][:status]).to eq("completed")
      expect(tool_part[:state][:output]).to eq("file contents here")
      expect(tool_part[:state][:time][:end]).to be_a(Integer)
    end

    it "tracks tool lifecycle: running → error" do
      asst_id = store.append_assistant

      store.add_tool_part(
        message_id: asst_id,
        tool: "shell",
        call_id: "call_002",
        input: { command: "rm -rf /" },
      )

      store.error_tool_part(
        message_id: asst_id,
        call_id: "call_002",
        error: "permission denied",
      )

      msg = store.message(asst_id)
      tool_part = msg[:parts].find { |p| p[:type] == "tool" }
      expect(tool_part[:state][:status]).to eq("error")
      expect(tool_part[:state][:error]).to eq("permission denied")
    end
  end

  describe "#complete_assistant" do
    it "sets completion time and token counts" do
      asst_id = store.append_assistant

      store.complete_assistant(
        message_id: asst_id,
        tokens: { input: 100, output: 50, reasoning: 10, cache: { read: 20, write: 5 } },
      )

      msg = store.message(asst_id)
      expect(msg[:info][:time][:completed]).to be_a(Integer)
      expect(msg[:info][:tokens][:input]).to eq(100)
      expect(msg[:info][:tokens][:output]).to eq(50)
      expect(msg[:info][:tokens][:reasoning]).to eq(10)
    end
  end

  describe "#messages" do
    it "returns all messages in order" do
      store.append_user(text: "Q1")
      store.append_assistant
      store.append_user(text: "Q2")

      msgs = store.messages
      expect(msgs.size).to eq(3)
      expect(msgs[0][:info][:role]).to eq("user")
      expect(msgs[1][:info][:role]).to eq("assistant")
      expect(msgs[2][:info][:role]).to eq("user")
    end
  end

  describe "#count" do
    it "returns the number of stored messages" do
      expect(store.count).to eq(0)

      store.append_user(text: "Q1")
      expect(store.count).to eq(1)

      store.append_assistant
      expect(store.count).to eq(2)
    end
  end

  describe "loading from disk" do
    it "restores messages from existing files" do
      store.append_user(text: "Persisted Q")
      asst_id = store.append_assistant(model_id: "claude")
      store.add_text_part(message_id: asst_id, text: "Persisted A")

      # Create a new store from the same directory
      store2 = described_class.new(session_id: session_id, dir: tmpdir)

      expect(store2.count).to eq(2)
      expect(store2.messages[0][:parts][0][:text]).to eq("Persisted Q")
      expect(store2.messages[1][:parts][0][:text]).to eq("Persisted A")
    end

    it "continues sequence numbering from loaded messages" do
      store.append_user(text: "Q1")
      store.append_user(text: "Q2")

      store2 = described_class.new(session_id: session_id, dir: tmpdir)
      id = store2.append_user(text: "Q3")

      expect(id).to eq("msg_0003")
    end
  end
end
