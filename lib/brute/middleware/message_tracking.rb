# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

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
        input = env[:input]
        case input
        when String
          input
        when Array
          # llm.rb prompt format: array of message hashes
          user_msg = input.reverse_each.find { |m| m.respond_to?(:role) && m.role.to_s == "user" }
          user_msg&.content.to_s if user_msg
        else
          # Could be a prompt object — try to extract user content
          if input.respond_to?(:messages)
            msgs = input.messages.to_a
            user_msg = msgs.reverse_each.find { |m| m.role.to_s == "user" }
            user_msg&.content.to_s if user_msg
          end
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

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Middleware::MessageTracking do
    let(:tmpdir) { Dir.mktmpdir("brute_test_") }
    let(:store) { Brute::Store::MessageStore.new(session_id: "test-session", dir: tmpdir) }
    let(:response) { MockResponse.new(content: "Hello from the LLM") }
    let(:inner_app) { ->(_env) { response } }
    let(:middleware) { described_class.new(inner_app, store: store) }

    after { FileUtils.rm_rf(tmpdir) }

    describe "user message recording" do
      it "records a user message on the first call of a turn" do
        env = build_env(input: "What is Ruby?", tool_results: nil)
        middleware.call(env)

        msgs = store.messages
        user_msg = msgs.find { |m| m[:info][:role] == "user" }
        expect(user_msg).not_to be_nil
        expect(user_msg[:parts][0][:text]).to eq("What is Ruby?")
      end

      it "does not record a user message on subsequent calls (tool results)" do
        env = build_env(input: "Hello", tool_results: nil)
        middleware.call(env)

        env[:tool_results] = [["read", "file contents"]]
        middleware.call(env)

        user_msgs = store.messages.select { |m| m[:info][:role] == "user" }
        expect(user_msgs.size).to eq(1)
      end
    end

    describe "assistant message recording" do
      it "records an assistant message after each LLM call" do
        env = build_env(input: "Hello", tool_results: nil)
        middleware.call(env)

        msgs = store.messages
        asst_msg = msgs.find { |m| m[:info][:role] == "assistant" }
        expect(asst_msg).not_to be_nil
        expect(asst_msg[:info][:parentID]).not_to be_nil
      end

      it "captures text content as a text part" do
        env = build_env(input: "Hello", tool_results: nil)
        middleware.call(env)

        asst_msg = store.messages.find { |m| m[:info][:role] == "assistant" }
        text_parts = asst_msg[:parts].select { |p| p[:type] == "text" }
        expect(text_parts.size).to eq(1)
        expect(text_parts[0][:text]).to eq("Hello from the LLM")
      end

      it "captures token usage from response" do
        env = build_env(input: "Hello", tool_results: nil)
        middleware.call(env)

        asst_msg = store.messages.find { |m| m[:info][:role] == "assistant" }
        expect(asst_msg[:info][:tokens][:input]).to eq(100)
        expect(asst_msg[:info][:tokens][:output]).to eq(50)
      end
    end

    describe "tool call recording" do
      it "records tool calls as tool parts in running state" do
        fn = double("function", id: "call_001", name: "read", arguments: { file_path: "/test" })

        env = build_env(input: "Read the file", tool_results: nil, pending_functions: [fn])
        middleware.call(env)

        asst_msg = store.messages.find { |m| m[:info][:role] == "assistant" }
        tool_parts = asst_msg[:parts].select { |p| p[:type] == "tool" }
        expect(tool_parts.size).to eq(1)
        expect(tool_parts[0][:tool]).to eq("read")
        expect(tool_parts[0][:callID]).to eq("call_001")
        expect(tool_parts[0][:state][:status]).to eq("running")
      end
    end

    describe "tool result completion" do
      it "updates tool parts when results arrive" do
        fn = double("function", id: "call_001", name: "read", arguments: { file_path: "/test" })

        env = build_env(input: "Read the file", tool_results: nil, pending_functions: [fn])
        middleware.call(env)

        env[:pending_functions] = []
        env[:tool_results] = [["read", "file contents here"]]
        middleware.call(env)

        msgs = store.messages
        first_asst = msgs.find { |m| m[:info][:role] == "assistant" }
        tool_part = first_asst[:parts].find { |p| p[:type] == "tool" }
        expect(tool_part[:state][:status]).to eq("completed")
        expect(tool_part[:state][:output]).to eq("file contents here")
      end
    end

    describe "model name resolution" do
      it "records the provider default_model when no override is set" do
        env = build_env(input: "Hello", tool_results: nil)
        middleware.call(env)

        asst_msg = store.messages.find { |m| m[:info][:role] == "assistant" }
        expect(asst_msg[:info][:modelID]).to eq("mock-model")
      end

      it "records the overridden model when env[:model] is set" do
        env = build_env(input: "Hello", tool_results: nil, model: "custom-haiku-model")
        middleware.call(env)

        asst_msg = store.messages.find { |m| m[:info][:role] == "assistant" }
        expect(asst_msg[:info][:modelID]).to eq("custom-haiku-model")
      end

      it "does not fall back to default_model when an override is present" do
        provider = MockProvider.new
        env = build_env(input: "Hello", tool_results: nil, model: "claude-3-haiku-20240307", provider: provider)
        middleware.call(env)

        asst_msg = store.messages.find { |m| m[:info][:role] == "assistant" }
        expect(asst_msg[:info][:modelID]).not_to eq(provider.default_model)
        expect(asst_msg[:info][:modelID]).to eq("claude-3-haiku-20240307")
      end
    end

    describe "middleware passthrough" do
      it "stores itself in env[:message_tracking]" do
        env = build_env(input: "Hello", tool_results: nil)
        middleware.call(env)

        expect(env[:message_tracking]).to eq(middleware)
      end

      it "returns the inner app response unchanged" do
        env = build_env(input: "Hello", tool_results: nil)
        result = middleware.call(env)

        expect(result).to eq(response)
      end
    end

    describe "step-finish parts" do
      it "adds a step-finish part to each assistant message" do
        env = build_env(input: "Hello", tool_results: nil)
        middleware.call(env)

        asst_msg = store.messages.find { |m| m[:info][:role] == "assistant" }
        step_finish = asst_msg[:parts].find { |p| p[:type] == "step-finish" }
        expect(step_finish).not_to be_nil
        expect(step_finish[:reason]).to eq("stop")
      end
    end
  end
end
