# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "json"
require "fileutils"
require "securerandom"

module Brute
  module Store
  # Append-only JSONL event store. Each event is a single JSON line in
  # `events.jsonl` inside the session directory.
  #
  # Storage layout:
  #
  #   ~/.brute/sessions/{session-id}/
  #     session.meta.json
  #     events.jsonl
  #
  # Every display-visible event (user input, agent text, tool calls,
  # log messages, errors) gets its own line:
  #
  #   {"seq":1,"type":"user","text":"Hello","time":1234567890,"sessionID":"..."}
  #   {"seq":2,"type":"log","text":"LLM call #1 ...","time":1234567891,"sessionID":"..."}
  #   {"seq":3,"type":"agent","text":"Hi there","time":1234567892,"sessionID":"...","modelID":"claude","providerID":"anthropic"}
  #   ...
  #
  # Event types: user, agent, tool, log, error
  #
  class MessageStore
    attr_reader :session_id, :dir

    def initialize(session_id:, dir: nil)
      @session_id = session_id
      @dir = dir || File.join(Dir.home, ".brute", "sessions", session_id)
      @events = []
      @seq = 0
      @mutex = Mutex.new
      load_existing
    end

    # ── Append methods ──────────────────────────────────────────

    def append_turn_start(provider_id:, model_id:)
      append_event(type: "turn-start", providerID: provider_id, modelID: model_id)
    end

    def append_user(text:)
      append_event(type: "user", text: text)
    end

    def append_agent(text:, model_id: nil, provider_id: nil)
      append_event(type: "agent", text: text, modelID: model_id, providerID: provider_id)
    end

    def append_log(text:, **fields)
      append_event(type: "log", text: text, **fields)
    end

    def append_error(text:)
      append_event(type: "error", text: text)
    end

    def append_tool_start(tool:, call_id:, input:)
      append_event(type: "tool", tool: tool, callID: call_id, status: "running", input: input)
    end

    def append_tool_complete(tool:, call_id:, output:)
      append_event(type: "tool", tool: tool, callID: call_id, status: "completed", output: output)
    end

    def append_tool_error(tool:, call_id:, error:)
      append_event(type: "tool", tool: tool, callID: call_id, status: "error", error: error.to_s)
    end

    # ── Readers ─────────────────────────────────────────────────

    def events
      @mutex.synchronize { @events.dup }
    end

    # Alias for backward compat with examples that call .messages
    alias_method :messages, :events

    def count
      @mutex.synchronize { @events.size }
    end

    private

      def append_event(type:, **fields)
        @mutex.synchronize do
          @seq += 1
          event = { seq: @seq, type: type, time: now_ts, sessionID: @session_id }
          event.merge!(fields.compact)
          @events << event
          persist_line(event)
          @seq
        end
      end

      def now_ts
        Time.now.strftime("%Y-%m-%dT%H:%M:%S.%L")
      end

      def persist_line(event)
        FileUtils.mkdir_p(@dir)
        path = File.join(@dir, "events.jsonl")
        File.open(path, "a") { |f| f.puts(JSON.generate(event)) }
      end

      def load_existing
        path = File.join(@dir, "events.jsonl")
        return unless File.exist?(path)

        File.foreach(path) do |line|
          line = line.strip
          next if line.empty?

          event = JSON.parse(line, symbolize_names: true)
          @events << event

          seq = event[:seq]
          @seq = seq if seq.is_a?(Integer) && seq > @seq
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

  it "appends a user event" do
    with_store do |store, _|
      store.append_user(text: "Hello")
      store.events.last[:type].should == "user"
      store.events.last[:text].should == "Hello"
    end
  end

  it "appends an agent event" do
    with_store do |store, _|
      store.append_agent(text: "Hi there", model_id: "claude", provider_id: "anthropic")
      e = store.events.last
      e[:type].should == "agent"
      e[:text].should == "Hi there"
      e[:modelID].should == "claude"
    end
  end

  it "appends a log event" do
    with_store do |store, _|
      store.append_log(text: "LLM call #1")
      store.events.last[:type].should == "log"
    end
  end

  it "appends an error event" do
    with_store do |store, _|
      store.append_error(text: "something broke")
      store.events.last[:type].should == "error"
    end
  end

  it "appends tool start and complete events" do
    with_store do |store, _|
      store.append_tool_start(tool: "shell", call_id: "c1", input: { "command" => "ls" })
      store.events.last[:status].should == "running"

      store.append_tool_complete(tool: "shell", call_id: "c1", output: "file1.rb")
      store.events.last[:status].should == "completed"
    end
  end

  it "appends tool error event" do
    with_store do |store, _|
      store.append_tool_start(tool: "shell", call_id: "c2", input: {})
      store.append_tool_error(tool: "shell", call_id: "c2", error: "denied")
      store.events.last[:status].should == "error"
    end
  end

  it "generates sequential seq numbers" do
    with_store do |store, _|
      store.append_user(text: "First")
      store.append_log(text: "log")
      store.append_agent(text: "response")
      store.events.map { |e| e[:seq] }.should == [1, 2, 3]
    end
  end

  it "returns count of stored events" do
    with_store do |store, _|
      store.count.should == 0
      store.append_user(text: "Q1")
      store.count.should == 1
    end
  end

  it "restores events from disk" do
    with_store do |store, dir|
      store.append_user(text: "Persisted Q")
      store.append_agent(text: "Persisted A", model_id: "claude")
      store2 = Brute::Store::MessageStore.new(session_id: "test-session-123", dir: dir)
      store2.count.should == 2
      store2.events[0][:text].should == "Persisted Q"
      store2.events[1][:text].should == "Persisted A"
    end
  end

  it "continues sequence numbering from loaded events" do
    with_store do |store, dir|
      store.append_user(text: "Q1")
      store.append_user(text: "Q2")
      store2 = Brute::Store::MessageStore.new(session_id: "test-session-123", dir: dir)
      store2.append_user(text: "Q3")
      store2.events.last[:seq].should == 3
    end
  end
end
