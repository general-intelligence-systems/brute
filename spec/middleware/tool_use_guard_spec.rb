# frozen_string_literal: true

RSpec.describe Brute::Middleware::ToolUseGuard do
  let(:provider) { MockProvider.new }

  # Build a minimal env hash like the orchestrator does
  def build_env(ctx)
    {
      context: ctx,
      provider: provider,
      tools: [],
      input: nil,
      params: {},
      metadata: {},
      tool_results: nil,
      streaming: false,
      callbacks: {},
    }
  end

  it "does nothing when there are no tool calls" do
    ctx = LLM::Context.new(provider, tools: [])
    response = MockResponse.new(content: "Just text, no tools")
    allow(provider).to receive(:complete).and_return(response)

    env = build_env(ctx)
    inner = ->(e) { e[:context].talk(e[:input]); response }
    middleware = described_class.new(inner)

    prompt = ctx.prompt { |p| p.system("test"); p.user("hello") }
    env[:input] = prompt
    middleware.call(env)

    messages = ctx.messages.to_a
    assistant_msgs = messages.select { |m| m.role.to_s == "assistant" }
    expect(assistant_msgs.size).to eq(1)
  end

  it "injects synthetic assistant message when tool calls exist but assistant is missing" do
    ctx = LLM::Context.new(provider, tools: [])

    # Simulate a tool-only response: choices[-1] is nil
    response = MockResponse.new(content: "")
    allow(response).to receive(:choices).and_return([nil])
    allow(provider).to receive(:complete).and_return(response)

    # We need functions to appear on the context after talk().
    # Since the real response is nil, functions won't be populated by llm.rb.
    # So we mock ctx.functions to return pending tool calls.
    mock_fn = instance_double(LLM::Function,
      id: "toolu_abc",
      name: "read",
      arguments: { "file_path" => "test.rb" },
      pending?: true,
    )

    env = build_env(ctx)
    inner = ->(e) {
      e[:context].talk(e[:input])
      # After talk, simulate that functions are available
      allow(e[:context]).to receive(:functions).and_return([mock_fn])
      response
    }
    middleware = described_class.new(inner)

    prompt = ctx.prompt { |p| p.system("test"); p.user("Read test.rb") }
    env[:input] = prompt
    middleware.call(env)

    messages = ctx.messages.to_a
    assistant_msg = messages.find { |m| m.role.to_s == "assistant" && m.tool_call? }

    expect(assistant_msg).not_to be_nil,
      "Expected middleware to inject synthetic assistant message with tool_use blocks"
    expect(assistant_msg.extra.original_tool_calls.first["id"]).to eq("toolu_abc")
  end

  it "does NOT inject when assistant message with tool_calls already exists" do
    ctx = LLM::Context.new(provider, tools: [])

    # Normal response with text + tool calls (choices[-1] is a valid Message)
    response = MockResponse.new(
      content: "Let me read that",
      tool_calls: [{ id: "toolu_xyz", name: "read", arguments: {} }],
    )
    allow(provider).to receive(:complete).and_return(response)

    mock_fn = instance_double(LLM::Function,
      id: "toolu_xyz", name: "read", arguments: {}, pending?: true,
    )

    env = build_env(ctx)
    inner = ->(e) {
      e[:context].talk(e[:input])
      allow(e[:context]).to receive(:functions).and_return([mock_fn])
      response
    }
    middleware = described_class.new(inner)

    prompt = ctx.prompt { |p| p.system("test"); p.user("Read file") }
    env[:input] = prompt
    middleware.call(env)

    messages = ctx.messages.to_a
    assistant_msgs = messages.select { |m| m.role.to_s == "assistant" }
    # Should have exactly 1 assistant message (the real one), not 2
    expect(assistant_msgs.size).to eq(1)
  end
end
