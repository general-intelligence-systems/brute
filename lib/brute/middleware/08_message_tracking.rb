# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Records every LLM exchange into a MessageStore in the OpenCode
    # {info, parts} format so sessions can be viewed later.
    #
    # Lifecycle per pipeline call:
    #
    #   1. PRE-CALL  — if this is the first call of a turn (env[:tool_results]
    #      is nil), record the user message.
    #   2. POST-CALL — record the assistant message: text content as a "text"
    #      part, each tool call as a "tool" part in "running" state.
    #   3. When the pipeline is called again with tool results, update the
    #      corresponding tool parts to "completed" (or "error").
    #
    # The middleware also stores itself in env[:message_tracking] so the
    # agent loop can access the current assistant message ID for callbacks.
    #
    class MessageTracking < Base
      attr_reader :store

      def initialize(app, store:)
        super(app)
        @store = store
        @current_user_id = nil
        @current_assistant_id = nil
      end

      def call(env)
        env[:message_tracking] = self

        # ── Pre-call: record user message or update tool results ──
        if env[:tool_results].nil?
          # New turn — record the user message
          record_user_message(env)
        else
          # Tool results coming back — complete the tool parts
          complete_tool_parts(env)
        end

        # ── LLM call ──
        response = @app.call(env)

        # ── Post-call: record assistant message ──
        record_assistant_message(env, response)

        response
      end

      # The current assistant message ID (used by external callbacks).
      def current_assistant_id
        @current_assistant_id
      end

      private

      # ── User message ───────────────────────────────────────────────

      def record_user_message(env)
        text = extract_user_text(env)
        return unless text

        @current_user_id = @store.append_user(text: text)
      end

      def extract_user_text(env)
        # Prefer the raw user text stashed by AgentTurn
        return env[:user_text] if env[:user_text].is_a?(String)

        input = env[:input]
        case input
        when String
          input
        when Array
          # llm.rb prompt format: array of message hashes
          user_msg = input.reverse_each.find { |m| m.respond_to?(:role) && m.role.to_s == "user" }
          user_msg&.content.to_s if user_msg
        end
      end

      # ── Assistant message ──────────────────────────────────────────

      def record_assistant_message(env, response)
        provider_name = env[:provider]&.class&.name&.split("::")&.last&.downcase
        model_name = resolve_model_name(env)

        @current_assistant_id = @store.append_assistant(
          parent_id: @current_user_id,
          model_id: model_name,
          provider_id: provider_name,
        )

        # Text content
        text = safe_content(response)
        @store.add_text_part(message_id: @current_assistant_id, text: text) if text && !text.empty?

        # Tool calls
        record_tool_calls(env)

        # Token usage
        tokens = extract_tokens(env, response)
        @store.complete_assistant(message_id: @current_assistant_id, tokens: tokens) if tokens

        # Step finish
        @store.add_step_finish(message_id: @current_assistant_id, tokens: tokens)
      end

      def record_tool_calls(env)
        functions = env[:pending_functions]
        return if functions.nil? || functions.empty?

        functions.each do |fn|
          @store.add_tool_part(
            message_id: @current_assistant_id,
            tool: fn.name,
            call_id: fn.id,
            input: fn.arguments,
          )
        end
      end

      # ── Tool results ───────────────────────────────────────────────

      def complete_tool_parts(env)
        return unless @current_assistant_id

        results = env[:tool_results]
        return unless results.is_a?(Array)

        results.each do |name, value|
          # Find the tool part by name (tool results come as [name, value] pairs)
          msg = @store.message(@current_assistant_id)
          next unless msg

          # Match by tool name — find the first running tool part with this name
          part = msg[:parts]&.find do |p|
            p[:type] == "tool" && p[:tool] == name && p.dig(:state, :status) == "running"
          end
          next unless part

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
      end

      # ── Helpers ────────────────────────────────────────────────────

      # Resolve the actual model used for the request.
      # Prefers env[:model] (set by AgentTurn) and falls back to the
      # provider's default_model.
      def resolve_model_name(env)
        model = env[:model]
        return model.to_s if model

        # Fall back to provider default
        env[:provider]&.respond_to?(:default_model) ? env[:provider].default_model.to_s : nil
      end

      def safe_content(response)
        return nil unless response.respond_to?(:content)
        response.content
      rescue NoMethodError
        nil
      end

      def extract_tokens(env, response)
        # Prefer the metadata accumulated by TokenTracking middleware
        meta_tokens = env.dig(:metadata, :tokens, :last_call)
        if meta_tokens
          {
            input: meta_tokens[:input] || 0,
            output: meta_tokens[:output] || 0,
            reasoning: 0,
            cache: { read: 0, write: 0 },
          }
        elsif response.respond_to?(:usage) && (usage = response.usage)
          {
            input: usage.input_tokens.to_i,
            output: usage.output_tokens.to_i,
            reasoning: usage.reasoning_tokens.to_i,
            cache: { read: 0, write: 0 },
          }
        end
      end
    end
  end
end

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"
  require "tmpdir"
  require "fileutils"

  def build_env(**overrides)
    { provider: MockProvider.new, model: nil, input: "test prompt", tools: [],
      messages: [], stream: nil, params: {}, metadata: {}, callbacks: {},
      tool_results: nil, streaming: false, should_exit: nil, pending_functions: [] }.merge(overrides)
  end

  def with_tracking
    tmpdir = Dir.mktmpdir("brute_test_")
    store = Brute::Store::MessageStore.new(session_id: "test-session", dir: tmpdir)
    response = MockResponse.new(content: "Hello from the LLM")
    inner_app = ->(_env) { response }
    middleware = Brute::Middleware::MessageTracking.new(inner_app, store: store)
    yield middleware, store, response
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  it "records a user message on first call of a turn" do
    with_tracking do |mw, store, _|
      mw.call(build_env(input: "What is Ruby?", tool_results: nil))
      user_msg = store.messages.find { |m| m[:info][:role] == "user" }
      user_msg[:parts][0][:text].should == "What is Ruby?"
    end
  end

  it "records only one user message per turn" do
    with_tracking do |mw, store, _|
      env = build_env(input: "Hello", tool_results: nil)
      mw.call(env)
      env[:tool_results] = [["read", "contents"]]
      mw.call(env)
      store.messages.select { |m| m[:info][:role] == "user" }.size.should == 1
    end
  end

  it "records an assistant message after LLM call" do
    with_tracking do |mw, store, _|
      mw.call(build_env(input: "Hello", tool_results: nil))
      asst = store.messages.find { |m| m[:info][:role] == "assistant" }
      asst.should.not.be.nil
    end
  end

  it "captures text content as a text part" do
    with_tracking do |mw, store, _|
      mw.call(build_env(input: "Hello", tool_results: nil))
      asst = store.messages.find { |m| m[:info][:role] == "assistant" }
      text_parts = asst[:parts].select { |p| p[:type] == "text" }
      text_parts[0][:text].should == "Hello from the LLM"
    end
  end

  it "captures token usage from response" do
    with_tracking do |mw, store, _|
      mw.call(build_env(input: "Hello", tool_results: nil))
      asst = store.messages.find { |m| m[:info][:role] == "assistant" }
      asst[:info][:tokens][:input].should == 100
    end
  end

  it "records tool calls as tool parts in running state" do
    with_tracking do |mw, store, _|
      fn = Struct.new(:id, :name, :arguments, keyword_init: true).new(id: "call_001", name: "read", arguments: { file_path: "/test" })
      mw.call(build_env(input: "Read the file", tool_results: nil, pending_functions: [fn]))
      asst = store.messages.find { |m| m[:info][:role] == "assistant" }
      tool_parts = asst[:parts].select { |p| p[:type] == "tool" }
      tool_parts[0][:state][:status].should == "running"
    end
  end

  it "updates tool parts when results arrive" do
    with_tracking do |mw, store, _|
      fn = Struct.new(:id, :name, :arguments, keyword_init: true).new(id: "call_001", name: "read", arguments: { file_path: "/test" })
      env = build_env(input: "Read the file", tool_results: nil, pending_functions: [fn])
      mw.call(env)
      env[:pending_functions] = []
      env[:tool_results] = [["read", "file contents here"]]
      mw.call(env)
      first_asst = store.messages.find { |m| m[:info][:role] == "assistant" }
      tool_part = first_asst[:parts].find { |p| p[:type] == "tool" }
      tool_part[:state][:status].should == "completed"
    end
  end

  it "records provider default_model when no override" do
    with_tracking do |mw, store, _|
      mw.call(build_env(input: "Hello", tool_results: nil))
      asst = store.messages.find { |m| m[:info][:role] == "assistant" }
      asst[:info][:modelID].should == "mock-model"
    end
  end

  it "records overridden model when env[:model] is set" do
    with_tracking do |mw, store, _|
      mw.call(build_env(input: "Hello", tool_results: nil, model: "custom-haiku"))
      asst = store.messages.find { |m| m[:info][:role] == "assistant" }
      asst[:info][:modelID].should == "custom-haiku"
    end
  end

  it "stores itself in env[:message_tracking]" do
    with_tracking do |mw, _, _|
      env = build_env(input: "Hello", tool_results: nil)
      mw.call(env)
      env[:message_tracking].should == mw
    end
  end

  it "returns the inner app response unchanged" do
    with_tracking do |mw, _, response|
      result = mw.call(build_env(input: "Hello", tool_results: nil))
      result.should == response
    end
  end

  it "adds a step-finish part to assistant messages" do
    with_tracking do |mw, store, _|
      mw.call(build_env(input: "Hello", tool_results: nil))
      asst = store.messages.find { |m| m[:info][:role] == "assistant" }
      step_finish = asst[:parts].find { |p| p[:type] == "step-finish" }
      step_finish[:reason].should == "stop"
    end
  end
end
