# frozen_string_literal: true

require "bundler/setup"
require "brute"
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

test do
  require "tmpdir"

  def with_store
    dir = Dir.mktmpdir("brute_test_")
    store = Brute::Store::MessageStore.new(session_id: "test-session-123", dir: dir)
    yield store, dir
  ensure
    FileUtils.rm_rf(dir)
  end

  it "creates a user message with text part" do
    with_store do |store, _|
      id = store.append_user(text: "Hello")
      store.message(id)[:info][:role].should == "user"
    end
  end

  it "stores user message text" do
    with_store do |store, _|
      id = store.append_user(text: "Hello")
      store.message(id)[:parts][0][:text].should == "Hello"
    end
  end

  it "generates sequential message IDs" do
    with_store do |store, _|
      id1 = store.append_user(text: "First")
      id2 = store.append_user(text: "Second")
      id1.should == "msg_0001"
    end
  end

  it "creates an assistant message" do
    with_store do |store, _|
      uid = store.append_user(text: "Hi")
      aid = store.append_assistant(parent_id: uid, model_id: "claude", provider_id: "anthropic")
      store.message(aid)[:info][:role].should == "assistant"
    end
  end

  it "appends a text part to an existing message" do
    with_store do |store, _|
      aid = store.append_assistant
      store.add_text_part(message_id: aid, text: "Here is my response")
      store.message(aid)[:parts][0][:text].should == "Here is my response"
    end
  end

  it "tracks tool lifecycle running to completed" do
    with_store do |store, _|
      aid = store.append_assistant
      store.add_tool_part(message_id: aid, tool: "read", call_id: "call_001", input: {})
      store.message(aid)[:parts].find { |p| p[:type] == "tool" }[:state][:status].should == "running"
      store.complete_tool_part(message_id: aid, call_id: "call_001", output: "done")
      store.message(aid)[:parts].find { |p| p[:type] == "tool" }[:state][:status].should == "completed"
    end
  end

  it "tracks tool lifecycle running to error" do
    with_store do |store, _|
      aid = store.append_assistant
      store.add_tool_part(message_id: aid, tool: "shell", call_id: "call_002", input: {})
      store.error_tool_part(message_id: aid, call_id: "call_002", error: "denied")
      store.message(aid)[:parts].find { |p| p[:type] == "tool" }[:state][:status].should == "error"
    end
  end

  it "sets token counts on complete_assistant" do
    with_store do |store, _|
      aid = store.append_assistant
      store.complete_assistant(message_id: aid, tokens: { input: 100, output: 50, reasoning: 10, cache: { read: 0, write: 0 } })
      store.message(aid)[:info][:tokens][:input].should == 100
    end
  end

  it "returns all messages in order" do
    with_store do |store, _|
      store.append_user(text: "Q1")
      store.append_assistant
      store.append_user(text: "Q2")
      store.messages.size.should == 3
    end
  end

  it "returns count of stored messages" do
    with_store do |store, _|
      store.count.should == 0
      store.append_user(text: "Q1")
      store.count.should == 1
    end
  end

  it "restores messages from disk" do
    with_store do |store, dir|
      store.append_user(text: "Persisted Q")
      aid = store.append_assistant(model_id: "claude")
      store.add_text_part(message_id: aid, text: "Persisted A")
      store2 = Brute::Store::MessageStore.new(session_id: "test-session-123", dir: dir)
      store2.count.should == 2
    end
  end

  it "continues sequence numbering from loaded messages" do
    with_store do |store, dir|
      store.append_user(text: "Q1")
      store.append_user(text: "Q2")
      store2 = Brute::Store::MessageStore.new(session_id: "test-session-123", dir: dir)
      store2.append_user(text: "Q3").should == "msg_0003"
    end
  end
end
