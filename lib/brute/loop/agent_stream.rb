# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Loop
  # Unified event bus and streaming bridge for agent turns.
  #
  # Every callback method both fires the user-provided callback (terminal
  # output) AND persists the event to the MessageStore. This guarantees
  # the session always reflects what the user saw on screen.
  #
  # Also implements the llm.rb streaming interface (on_content,
  # on_reasoning_content, on_tool_call) so it can be passed directly as
  # the stream object to LLM::Context.
  #
  # Usage:
  #
  #   stream = AgentStream.new(
  #     message_store: session.message_store,
  #     on_log:     ->(text) { ... },
  #     on_content: ->(text) { ... },
  #     ...
  #   )
  #
  #   # Message lifecycle
  #   stream.start_user_message(text: "Hello")
  #   stream.start_assistant_message(model_id: "claude", provider_id: "anthropic")
  #
  #   # Events (fire callback + persist)
  #   stream.on_content("Here is my response")
  #   stream.on_tool_call_start([{ name: "shell", call_id: "c1", arguments: {} }])
  #   stream.on_tool_result("shell", "file1.rb")
  #
  #   stream.complete_assistant_message(tokens: { input: 100, output: 50 })
  #
  class AgentStream
    attr_reader :current_user_id, :current_assistant_id, :store

    # Tool call metadata recorded during streaming, used by ToolUseGuard
    # when ctx.functions is empty (nil-choice bug in llm.rb).
    attr_reader :pending_tool_calls

    # Deferred tool/error pairs: [(LLM::Function, error_or_nil), ...]
    # The agent loop reads these after the stream completes.
    attr_reader :pending_tools

    def initialize(message_store:, **callbacks)
      @store = message_store

      @cb_on_log             = callbacks[:on_log]
      @cb_on_content         = callbacks[:on_content]
      @cb_on_reasoning       = callbacks[:on_reasoning]
      @cb_on_error           = callbacks[:on_error]
      @cb_on_tool_call_start = callbacks[:on_tool_call_start]
      @cb_on_tool_result     = callbacks[:on_tool_result]
      @cb_on_question        = callbacks[:on_question]

      @current_user_id = nil
      @current_assistant_id = nil
      @pending_tool_calls = []
      @pending_tools = []
    end

    # ── Message lifecycle ─────────────────────────────────────────

    def start_user_message(text:)
      @current_user_id = @store.append_user(text: text)
    end

    def start_assistant_message(parent_id: nil, model_id: nil, provider_id: nil)
      @current_assistant_id = @store.append_assistant(
        parent_id: parent_id || @current_user_id,
        model_id: model_id,
        provider_id: provider_id,
      )
    end

    def complete_assistant_message(tokens: nil)
      return unless @current_assistant_id

      @store.complete_assistant(message_id: @current_assistant_id, tokens: tokens)
      @store.add_step_finish(message_id: @current_assistant_id, tokens: tokens)
    end

    # ── Callback + persist methods ────────────────────────────────

    def on_log(text)
      @cb_on_log&.call(text)
      return unless @current_assistant_id

      @store.add_log_part(message_id: @current_assistant_id, text: text)
    end

    # Called by middleware (non-streaming) and by llm.rb (streaming).
    def on_content(text)
      @cb_on_content&.call(text)
      return unless @current_assistant_id

      @store.add_text_part(message_id: @current_assistant_id, text: text)
    end

    def on_reasoning(text)
      @cb_on_reasoning&.call(text)
      # Reasoning is ephemeral — not persisted to the session.
    end

    # llm.rb streaming interface calls this for reasoning chunks.
    def on_reasoning_content(text)
      on_reasoning(text)
    end

    def on_error(text)
      @cb_on_error&.call(text)
      return unless @current_assistant_id

      @store.add_error_part(message_id: @current_assistant_id, text: text)
    end

    def on_tool_call_start(batch)
      @cb_on_tool_call_start&.call(batch)
      return unless @current_assistant_id

      batch.each do |tc|
        @store.add_tool_part(
          message_id: @current_assistant_id,
          tool: tc[:name],
          call_id: tc[:call_id] || tc[:id],
          input: tc[:arguments],
        )
      end
    end

    def on_tool_result(name, value)
      @cb_on_tool_result&.call(name, value)
      return unless @current_assistant_id

      msg = @store.message(@current_assistant_id)
      return unless msg

      # Find the first running tool part with this name
      part = msg[:parts]&.find do |p|
        p[:type] == "tool" && p[:tool] == name && p.dig(:state, :status) == "running"
      end
      return unless part

      call_id = part[:callID]
      if value.is_a?(Hash) && value[:error]
        @store.error_tool_part(
          message_id: @current_assistant_id,
          call_id: call_id,
          error: value[:error],
        )
      else
        output = value.is_a?(String) ? value : value.to_s
        @store.complete_tool_part(
          message_id: @current_assistant_id,
          call_id: call_id,
          output: output,
        )
      end
    end

    # Returns the on_question callback (used by Question middleware
    # to set Thread.current[:on_question]).
    def on_question
      @cb_on_question
    end

    # ── llm.rb streaming interface ────────────────────────────────

    # Called by llm.rb per tool as it arrives during streaming.
    # Records only — no execution, no threads, no queue pushes.
    def on_tool_call(tool, error)
      @pending_tool_calls << { id: tool.id, name: tool.name, arguments: tool.arguments }
      @pending_tools << [tool, error]
    end

    # Clear only the tool call metadata (used by ToolUseGuard after it
    # has consumed the data for synthetic message injection).
    def clear_pending_tool_calls!
      @pending_tool_calls.clear
    end

    # Clear the deferred execution queue after the agent loop has
    # consumed and dispatched all tool calls.
    def clear_pending_tools!
      @pending_tools.clear
    end
  end
  end
end

test do
  require "tmpdir"
  require "fileutils"

  FakeTool = Struct.new(:id, :name, :arguments, keyword_init: true)

  def make_stream(**callbacks)
    tmpdir = Dir.mktmpdir("brute_test_")
    store = Brute::Store::MessageStore.new(session_id: "test-session", dir: tmpdir)
    stream = Brute::Loop::AgentStream.new(message_store: store, **callbacks)
    [stream, store, tmpdir]
  end

  it "records tool in pending_tools" do
    stream, _, tmpdir = make_stream
    tool = FakeTool.new(id: "toolu_1", name: "read", arguments: {})
    stream.on_tool_call(tool, nil)
    stream.pending_tools.size.should == 1
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it "records tool call metadata" do
    stream, _, tmpdir = make_stream
    tool = FakeTool.new(id: "toolu_abc", name: "read", arguments: { "file_path" => "test.rb" })
    stream.on_tool_call(tool, nil)
    stream.pending_tool_calls.first[:id].should == "toolu_abc"
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it "records multiple tool calls" do
    stream, _, tmpdir = make_stream
    t1 = FakeTool.new(id: "toolu_1", name: "read", arguments: {})
    t2 = FakeTool.new(id: "toolu_2", name: "write", arguments: {})
    stream.on_tool_call(t1, nil)
    stream.on_tool_call(t2, nil)
    stream.pending_tool_calls.size.should == 2
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it "clears pending tool calls and tools" do
    stream, _, tmpdir = make_stream
    tool = FakeTool.new(id: "toolu_1", name: "read", arguments: {})
    stream.on_tool_call(tool, nil)
    stream.clear_pending_tool_calls!
    stream.clear_pending_tools!
    stream.pending_tool_calls.should.be.empty
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it "fires the content callback" do
    received = nil
    stream, _, tmpdir = make_stream(on_content: ->(text) { received = text })
    stream.on_content("hello")
    received.should == "hello"
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it "fires the reasoning callback" do
    received = nil
    stream, _, tmpdir = make_stream(on_reasoning: ->(text) { received = text })
    stream.on_reasoning_content("thinking...")
    received.should == "thinking..."
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it "persists on_content as text part on current assistant" do
    stream, store, tmpdir = make_stream
    stream.start_user_message(text: "hi")
    stream.start_assistant_message(model_id: "claude", provider_id: "anthropic")
    stream.on_content("Hello there")
    asst = store.messages.find { |m| m[:info][:role] == "assistant" }
    asst[:parts].find { |p| p[:type] == "text" }[:text].should == "Hello there"
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it "persists on_log as log part on current assistant" do
    stream, store, tmpdir = make_stream
    stream.start_user_message(text: "hi")
    stream.start_assistant_message(model_id: "claude", provider_id: "anthropic")
    stream.on_log("LLM call #1")
    asst = store.messages.find { |m| m[:info][:role] == "assistant" }
    asst[:parts].find { |p| p[:type] == "log" }[:text].should == "LLM call #1"
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it "persists on_error as error part on current assistant" do
    stream, store, tmpdir = make_stream
    stream.start_user_message(text: "hi")
    stream.start_assistant_message(model_id: "claude", provider_id: "anthropic")
    stream.on_error("something broke")
    asst = store.messages.find { |m| m[:info][:role] == "assistant" }
    asst[:parts].find { |p| p[:type] == "error" }[:text].should == "something broke"
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it "persists tool lifecycle through on_tool_call_start and on_tool_result" do
    stream, store, tmpdir = make_stream
    stream.start_user_message(text: "hi")
    stream.start_assistant_message(model_id: "claude", provider_id: "anthropic")
    stream.on_tool_call_start([{ name: "shell", call_id: "c1", arguments: { "command" => "ls" } }])
    asst = store.messages.find { |m| m[:info][:role] == "assistant" }
    tool_part = asst[:parts].find { |p| p[:type] == "tool" }
    tool_part[:state][:status].should == "running"

    stream.on_tool_result("shell", "file1.rb")
    asst = store.message(stream.current_assistant_id)
    tool_part = asst[:parts].find { |p| p[:type] == "tool" }
    tool_part[:state][:status].should == "completed"
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it "creates user and assistant messages in store" do
    stream, store, tmpdir = make_stream
    stream.start_user_message(text: "What is Ruby?")
    stream.start_assistant_message(model_id: "claude", provider_id: "anthropic")
    stream.complete_assistant_message(tokens: { input: 100, output: 50, reasoning: 0, cache: { read: 0, write: 0 } })
    store.messages.size.should == 2
    store.messages[0][:info][:role].should == "user"
    store.messages[1][:info][:role].should == "assistant"
  ensure
    FileUtils.rm_rf(tmpdir)
  end
end
