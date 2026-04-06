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

  # ── Bug: streaming tool-only response — ctx.functions is empty ────────
  #
  # When the LLM responds with ONLY tool_use blocks in streaming mode:
  #   1. AgentStream#on_tool_call fires and spawns tool threads
  #   2. llm.rb's adapt_choices produces nil (no text → empty choices)
  #   3. Context#talk appends nil, BufferNilGuard strips it
  #   4. No assistant message is stored → ctx.functions returns empty
  #   5. The guard sees functions.empty? → skips injection
  #   6. Orchestrator loop sees functions.empty? → breaks immediately
  #   7. Tool results are never sent back to the LLM → no response
  #
  # The guard must fall back to the stream's pending_tool_calls metadata
  # when ctx.functions is empty but the stream has pending tool work.
  #
  # This test will FAIL until the guard checks the stream fallback.

  it "injects using stream tool metadata when ctx.functions is empty (streaming)" do
    # Set up a stream that recorded tool call metadata
    stream = Brute::AgentStream.new

    # Simulate the stream having recorded a tool call during on_tool_call.
    # We can't call stream.on_tool_call with a real LLM::Function (needs
    # runner), so we stub the pending_tool_calls directly on the stream
    # for now. The agent_stream_spec tests the recording itself.
    #
    # When the fix lands, AgentStream#on_tool_call will populate this,
    # and the guard will read it.
    tool_metadata = [
      { id: "toolu_stream1", name: "read", arguments: { "file_path" => "readme.md" } },
    ]
    allow(stream).to receive(:pending_tool_calls).and_return(tool_metadata)

    # Create context WITH the stream (as the orchestrator does)
    ctx = LLM::Context.new(provider, tools: [], stream: stream)

    # Simulate a tool-only response: nil choice → no assistant message stored
    response = MockResponse.new(content: "")
    allow(response).to receive(:choices).and_return([nil])
    allow(provider).to receive(:complete).and_return(response)

    prompt = ctx.prompt { |p| p.system("test"); p.user("Read the readme") }

    inner = ->(e) {
      e[:context].talk(e[:input])
      # ctx.functions is empty because no assistant message was stored
      # (this is the actual llm.rb behavior with nil choices)
      response
    }
    middleware = described_class.new(inner)

    env = build_env(ctx)
    env[:streaming] = true
    env[:input] = prompt
    middleware.call(env)

    # The guard must detect pending tool work via the stream and inject
    # a synthetic assistant message with the correct tool_use IDs.
    messages = ctx.messages.to_a
    synthetic = messages.find do |m|
      m.role.to_s == "assistant" &&
        m.tool_call? &&
        m.extra.original_tool_calls&.any? { |tc| tc["id"] == "toolu_stream1" }
    end

    expect(synthetic).not_to be_nil,
      "Expected guard to inject synthetic assistant message using stream's " \
      "pending_tool_calls when ctx.functions is empty in streaming mode. " \
      "Without this, the orchestrator loop exits immediately and the tool " \
      "results are never sent back to the LLM."

    # Verify the injected message has the correct tool call data
    tc = synthetic.extra.original_tool_calls.first
    expect(tc["id"]).to eq("toolu_stream1")
    expect(tc["name"]).to eq("read")
    # input may be wrapped in LLM::Object by the message's extra hash
    input = tc["input"].respond_to?(:to_h) ? tc["input"].to_h : tc["input"]
    expect(input).to eq({ "file_path" => "readme.md" })
  end

  # ── Bug: guard only checks last_assistant.tool_call? boolean ──────────
  #
  # The guard checks whether the last assistant message has tool_call? true,
  # but does NOT verify that the specific tool_use IDs from ctx.functions
  # are actually present in that assistant message's original_tool_calls.
  #
  # Scenario: the last assistant message has tool_call? from a PREVIOUS
  # tool invocation (different IDs), but the current pending functions
  # have NEW IDs that aren't in the buffer at all. The guard sees
  # tool_call? == true and skips injection. The next API call sends
  # tool_result referencing IDs that don't exist → "unexpected tool_use_id".
  #
  # This test will FAIL until the fix is applied.

  it "injects when pending function IDs are not in the last assistant message" do
    ctx = LLM::Context.new(provider, tools: [])

    # First response: text + tool call with ID "toolu_OLD"
    first_response = MockResponse.new(
      content: "Let me read that",
      tool_calls: [{ id: "toolu_OLD", name: "read", arguments: {} }],
    )
    allow(provider).to receive(:complete).and_return(first_response)

    prompt = ctx.prompt { |p| p.system("test"); p.user("Read file") }
    ctx.talk(prompt)

    # Verify the assistant message with toolu_OLD is in the buffer
    last_assistant = ctx.messages.to_a.reverse.find { |m| m.role.to_s == "assistant" }
    expect(last_assistant).not_to be_nil
    expect(last_assistant.tool_call?).to be true

    # Now simulate a NEW set of pending functions with DIFFERENT IDs.
    # This happens when a second LLM call returns tool-only (nil choice),
    # the assistant message is dropped, but streaming resolved the tools.
    mock_fn = instance_double(LLM::Function,
      id: "toolu_NEW",
      name: "write",
      arguments: { "file_path" => "out.rb" },
      pending?: true,
    )

    # The inner app does NOT add a new assistant message (simulating the
    # nil-choice bug on the second LLM call)
    second_response = MockResponse.new(content: "")
    inner = ->(e) {
      allow(e[:context]).to receive(:functions).and_return([mock_fn])
      second_response
    }
    middleware = described_class.new(inner)

    env = build_env(ctx)
    env[:input] = "tool results from first call"
    middleware.call(env)

    # The guard must detect that "toolu_NEW" is NOT covered by any
    # assistant message and inject a synthetic one.
    messages = ctx.messages.to_a
    synthetic = messages.find do |m|
      m.role.to_s == "assistant" &&
        m.tool_call? &&
        m.extra.original_tool_calls&.any? { |tc| tc["id"] == "toolu_NEW" }
    end

    expect(synthetic).not_to be_nil,
      "Expected guard to inject synthetic assistant message for toolu_NEW, " \
      "but it was not found. The guard only checks last_assistant.tool_call? " \
      "(which is true from toolu_OLD) without verifying the specific IDs match."
  end

  # ── Bug: stale pending_tool_calls cause duplicate synthetic messages ──
  #
  # After the guard consumes stream.pending_tool_calls and injects a
  # synthetic assistant message, it must clear the stream's metadata.
  # Otherwise, on the NEXT pipeline.call (sending tool results back),
  # the guard reads stale IDs and may inject orphaned tool_use blocks.
  # Anthropic then rejects the next user message with:
  #   "tool_use ids were found without tool_result blocks"

  it "clears stream pending_tool_calls after consuming them" do
    stream = Brute::AgentStream.new

    tool_metadata = [
      { id: "toolu_clear1", name: "read", arguments: {} },
    ]
    # Simulate tool call metadata recorded during streaming
    tool_metadata.each { |td| stream.instance_variable_get(:@pending_tool_calls) << td }

    ctx = LLM::Context.new(provider, tools: [], stream: stream)

    # Nil-choice response — no assistant message stored
    response = MockResponse.new(content: "")
    allow(response).to receive(:choices).and_return([nil])
    allow(provider).to receive(:complete).and_return(response)

    prompt = ctx.prompt { |p| p.system("test"); p.user("read it") }

    inner = ->(e) { e[:context].talk(e[:input]); response }
    middleware = described_class.new(inner)

    env = build_env(ctx)
    env[:streaming] = true
    env[:input] = prompt
    middleware.call(env)

    # Guard should have injected a synthetic message
    messages = ctx.messages.to_a
    has_synthetic = messages.any? { |m|
      m.role.to_s == "assistant" && m.tool_call? &&
        m.extra.original_tool_calls&.any? { |tc| tc["id"] == "toolu_clear1" }
    }
    expect(has_synthetic).to be(true), "Guard should have injected synthetic message"

    # And cleared the stream's pending_tool_calls
    expect(stream.pending_tool_calls).to be_empty,
      "Guard must clear stream.pending_tool_calls after consuming them. " \
      "Stale entries cause duplicate synthetic messages on subsequent calls."
  end

  it "does not inject duplicates on a second pipeline.call after tool results" do
    stream = Brute::AgentStream.new

    tool_metadata = [
      { id: "toolu_dup1", name: "todo_write", arguments: {} },
    ]
    tool_metadata.each { |td| stream.instance_variable_get(:@pending_tool_calls) << td }

    ctx = LLM::Context.new(provider, tools: [], stream: stream)

    # First call: nil-choice response, guard injects synthetic
    nil_response = MockResponse.new(content: "")
    allow(nil_response).to receive(:choices).and_return([nil])
    allow(provider).to receive(:complete).and_return(nil_response)

    prompt = ctx.prompt { |p| p.system("test"); p.user("write a todo") }

    inner1 = ->(e) { e[:context].talk(e[:input]); nil_response }
    middleware = described_class.new(inner1)

    env = build_env(ctx)
    env[:streaming] = true
    env[:input] = prompt
    middleware.call(env)

    assistant_count_after_first = ctx.messages.to_a.count { |m|
      m.role.to_s == "assistant" && m.tool_call?
    }

    # Second call: sending tool results back, LLM responds with text only
    text_response = MockResponse.new(content: "Done!")
    allow(provider).to receive(:complete).and_return(text_response)

    inner2 = ->(e) { e[:context].talk(e[:input]); text_response }
    middleware2 = described_class.new(inner2)

    env2 = build_env(ctx)
    env2[:streaming] = true
    env2[:input] = "tool results"
    middleware2.call(env2)

    assistant_count_after_second = ctx.messages.to_a.count { |m|
      m.role.to_s == "assistant" && m.tool_call?
    }

    # No new synthetic assistant message should have been injected
    expect(assistant_count_after_second).to eq(assistant_count_after_first),
      "Guard injected a duplicate synthetic assistant message on the second " \
      "pipeline.call. This creates orphaned tool_use blocks that cause " \
      "'tool_use ids found without tool_result' errors on the next turn."
  end
end
