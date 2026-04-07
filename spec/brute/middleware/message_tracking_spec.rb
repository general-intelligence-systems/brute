# frozen_string_literal: true

require "tmpdir"

RSpec.describe Brute::Middleware::MessageTracking do
  let(:tmpdir) { Dir.mktmpdir("brute_test_") }
  let(:store) { Brute::MessageStore.new(session_id: "test-session", dir: tmpdir) }
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
      # First call (new turn)
      env = build_env(input: "Hello", tool_results: nil)
      middleware.call(env)

      # Second call (tool results coming back)
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
      # Mock functions on the context
      fn = double("function", id: "call_001", name: "read", arguments: { file_path: "/test" })
      provider = MockProvider.new
      ctx = LLM::Context.new(provider, tools: [])
      allow(ctx).to receive(:functions).and_return([fn])
      allow(provider).to receive(:complete).and_return(response)

      env = build_env(input: "Read the file", tool_results: nil, context: ctx)
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
      # First call: record the tool call
      fn = double("function", id: "call_001", name: "read", arguments: { file_path: "/test" })
      provider = MockProvider.new
      ctx = LLM::Context.new(provider, tools: [])
      allow(ctx).to receive(:functions).and_return([fn])
      allow(provider).to receive(:complete).and_return(response)

      env = build_env(input: "Read the file", tool_results: nil, context: ctx)
      middleware.call(env)

      # Second call: tool results
      allow(ctx).to receive(:functions).and_return([])
      env[:tool_results] = [["read", "file contents here"]]
      middleware.call(env)

      # The first assistant message's tool part should now be completed
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

    it "records the overridden model when context was created with model:" do
      provider = MockProvider.new
      ctx = LLM::Context.new(provider, tools: [], model: "custom-haiku-model")

      env = build_env(input: "Hello", tool_results: nil, context: ctx, provider: provider)
      middleware.call(env)

      asst_msg = store.messages.find { |m| m[:info][:role] == "assistant" }
      expect(asst_msg[:info][:modelID]).to eq("custom-haiku-model")
    end

    it "does not fall back to default_model when an override is present" do
      provider = MockProvider.new
      ctx = LLM::Context.new(provider, tools: [], model: "claude-3-haiku-20240307")

      env = build_env(input: "Hello", tool_results: nil, context: ctx, provider: provider)
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
