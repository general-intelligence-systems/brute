# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

module Brute
  module Store
  # Stores session messages as individual JSON files in the OpenCode
  # {info, parts} format. Each session gets a directory; each message
  # is a numbered JSON file inside it.
  #
  # Storage layout:
  #
  #   ~/.brute/sessions/{session-id}/
  #     session.meta.json
  #     msg_0001.json
  #     msg_0002.json
  #     ...
  #
  # Message format matches OpenCode's MessageV2.WithParts:
  #
  #   { info: { id:, sessionID:, role:, time:, ... },
  #     parts: [{ id:, type:, ... }, ...] }
  #
  class MessageStore
    attr_reader :session_id, :dir

    def initialize(session_id:, dir: nil)
      @session_id = session_id
      @dir = dir || File.join(Dir.home, ".brute", "sessions", session_id)
      @messages = {}   # id => { info:, parts: }
      @seq = 0
      @part_seq = 0
      @mutex = Mutex.new
      load_existing
    end

    def append_user(text:, message_id: nil)
      id = message_id || next_message_id
      msg = {
        info: {
          id: id,
          sessionID: @session_id,
          role: "user",
          time: { created: now_ms },
        },
        parts: [
          { id: next_part_id, sessionID: @session_id, messageID: id,
            type: "text", text: text },
        ],
      }
      save_message(id, msg)
      id
    end

    def append_assistant(message_id: nil, parent_id: nil, model_id: nil, provider_id: nil)
      id = message_id || next_message_id
      msg = {
        info: {
          id: id,
          sessionID: @session_id,
          role: "assistant",
          parentID: parent_id,
          time: { created: now_ms },
          modelID: model_id,
          providerID: provider_id,
          tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
          cost: 0.0,
        },
        parts: [],
      }
      save_message(id, msg)
      id
    end

    def add_text_part(message_id:, text:)
      @mutex.synchronize do
        msg = @messages[message_id]
        return unless msg

        part = { id: next_part_id, sessionID: @session_id, messageID: message_id,
                 type: "text", text: text }
        msg[:parts] << part
        persist(message_id)
        part[:id]
      end
    end

    def add_tool_part(message_id:, tool:, call_id:, input:)
      @mutex.synchronize do
        msg = @messages[message_id]
        return unless msg

        part = {
          id: next_part_id, sessionID: @session_id, messageID: message_id,
          type: "tool", callID: call_id, tool: tool,
          state: {
            status: "running",
            input: input,
            time: { start: now_ms },
          },
        }
        msg[:parts] << part
        persist(message_id)
        part[:id]
      end
    end

    def complete_tool_part(message_id:, call_id:, output:)
      @mutex.synchronize do
        msg = @messages[message_id]
        return unless msg

        part = msg[:parts].find { |p| p[:type] == "tool" && p[:callID] == call_id }
        return unless part

        part[:state][:status] = "completed"
        part[:state][:output] = output
        part[:state][:time][:end] = now_ms
        persist(message_id)
      end
    end

    def error_tool_part(message_id:, call_id:, error:)
      @mutex.synchronize do
        msg = @messages[message_id]
        return unless msg

        part = msg[:parts].find { |p| p[:type] == "tool" && p[:callID] == call_id }
        return unless part

        part[:state][:status] = "error"
        part[:state][:error] = error.to_s
        part[:state][:time][:end] = now_ms
        persist(message_id)
      end
    end

    def add_step_finish(message_id:, tokens: nil)
      @mutex.synchronize do
        msg = @messages[message_id]
        return unless msg

        part = {
          id: next_part_id, sessionID: @session_id, messageID: message_id,
          type: "step-finish",
          reason: "stop",
          tokens: tokens || { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
        }
        msg[:parts] << part
        persist(message_id)
      end
    end

    # Finalize an assistant message with token counts and completion time.
    def complete_assistant(message_id:, tokens: nil)
      @mutex.synchronize do
        msg = @messages[message_id]
        return unless msg

        msg[:info][:time][:completed] = now_ms
        if tokens
          msg[:info][:tokens] = {
            input: tokens[:input] || tokens[:total_input] || 0,
            output: tokens[:output] || tokens[:total_output] || 0,
            reasoning: tokens[:reasoning] || tokens[:total_reasoning] || 0,
            cache: tokens[:cache] || { read: 0, write: 0 },
          }
        end
        persist(message_id)
      end
    end

    def messages
      @mutex.synchronize { @messages.values }
    end

    def message(id)
      @mutex.synchronize { @messages[id] }
    end

    def count
      @mutex.synchronize { @messages.size }
    end

    private

      def next_message_id
        @seq += 1
        format("msg_%04d", @seq)
      end

      def next_part_id
        @part_seq += 1
        format("prt_%04d", @part_seq)
      end

      def now_ms
        (Time.now.to_f * 1000).to_i
      end

      def save_message(id, msg)
        @mutex.synchronize do
          @messages[id] = msg
          persist(id)
        end
      end

      def persist(id)
        FileUtils.mkdir_p(@dir)
        msg = @messages[id]
        return unless msg

        path = File.join(@dir, "#{id}.json")
        File.write(path, JSON.pretty_generate(msg))
      end

      def load_existing
        return unless File.directory?(@dir)

        Dir.glob(File.join(@dir, "msg_*.json")).sort.each do |path|
          data = JSON.parse(File.read(path), symbolize_names: true)
          id = data.dig(:info, :id)
          next unless id

          @messages[id] = data

          # Track sequence numbers so new IDs don't collide
          if (m = id.match(/\Amsg_(\d+)\z/))
            n = m[1].to_i
            @seq = n if n > @seq
          end

          # Track part sequences too
          (data[:parts] || []).each do |part|
            pid = part[:id]
            if pid.is_a?(String) && (m = pid.match(/\Aprt_(\d+)\z/))
              n = m[1].to_i
              @part_seq = n if n > @part_seq
            end
          end
        end
      end
  end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  require "tmpdir"

  RSpec.describe Brute::Store::MessageStore do
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
end
