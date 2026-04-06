# frozen_string_literal: true

RSpec.describe Brute::Middleware::CompactionCheck do
  let(:response) { MockResponse.new(content: "compaction response") }
  let(:inner_app) { ->(_env) { response } }
  let(:compactor) { double("compactor") }
  let(:system_prompt) { "You are a helpful assistant." }
  let(:tools) { [] }
  let(:middleware) do
    described_class.new(inner_app, compactor: compactor, system_prompt: system_prompt, tools: tools)
  end

  it "passes the response through when compaction is not needed" do
    allow(compactor).to receive(:should_compact?).and_return(false)
    env = build_env

    result = middleware.call(env)

    expect(result).to eq(response)
    expect(env[:metadata][:compaction]).to be_nil
  end

  it "does not replace context when compaction is not triggered" do
    allow(compactor).to receive(:should_compact?).and_return(false)
    env = build_env
    original_ctx = env[:context]

    middleware.call(env)

    expect(env[:context]).to equal(original_ctx)
  end

  it "triggers compaction and rebuilds context when threshold is exceeded" do
    allow(compactor).to receive(:should_compact?).and_return(true)
    allow(compactor).to receive(:compact).and_return(["Summary of conversation", []])

    provider = MockProvider.new
    ctx = LLM::Context.new(provider, tools: [])
    # Populate with a few messages so messages.size > 0
    prompt = ctx.prompt { |p| p.system("sys"); p.user("hello") }
    ctx.talk(prompt)

    env = build_env(context: ctx, provider: provider)
    middleware.call(env)

    expect(env[:metadata][:compaction]).to include(:messages_before, :timestamp)
    # Context should be replaced
    expect(env[:context]).not_to equal(ctx)
  end

  it "handles compactor returning nil gracefully" do
    allow(compactor).to receive(:should_compact?).and_return(true)
    allow(compactor).to receive(:compact).and_return(nil)

    env = build_env
    original_ctx = env[:context]

    middleware.call(env)

    # Context should NOT be replaced
    expect(env[:context]).to equal(original_ctx)
    expect(env[:metadata][:compaction]).to be_nil
  end

  # ── Bug: rebuild_context! drops the stream parameter ──────────────────
  #
  # When compaction fires, rebuild_context! creates a new LLM::Context
  # without passing the stream: param. This means:
  #   1. Streaming callbacks (on_content) stop firing on the new context
  #   2. env[:streaming] remains true, so the LLMCall post-hoc fallback
  #      is also skipped
  #   3. LLM response content is silently lost
  #
  # These tests will FAIL until the fix is applied.

  context "when streaming is enabled" do
    let(:stream) { double("AgentStream") }

    let(:middleware_with_stream) do
      described_class.new(inner_app,
        compactor: compactor,
        system_prompt: system_prompt,
        tools: tools,
        stream: stream,
      )
    end

    it "preserves the stream parameter on the rebuilt context" do
      allow(compactor).to receive(:should_compact?).and_return(true)
      allow(compactor).to receive(:compact).and_return(["Summary of conversation", []])

      provider = MockProvider.new
      original_ctx = LLM::Context.new(provider, tools: [], stream: stream)
      prompt = original_ctx.prompt { |p| p.system("sys"); p.user("hello") }
      original_ctx.talk(prompt)

      env = build_env(context: original_ctx, provider: provider, streaming: true)
      middleware_with_stream.call(env)

      new_ctx = env[:context]
      expect(new_ctx).not_to equal(original_ctx)

      # The rebuilt context must carry the stream so that subsequent
      # ctx.talk() calls trigger streaming callbacks.
      ctx_params = new_ctx.instance_variable_get(:@params)
      expect(ctx_params[:stream]).to eq(stream),
        "Expected rebuilt context to have stream: #{stream.inspect} " \
        "in @params, but got: #{ctx_params[:stream].inspect}. " \
        "This causes on_content callbacks to silently stop firing after compaction."
    end

    it "fires on_content callback on the rebuilt context when streaming" do
      received_content = nil
      callback = ->(text) { received_content = text }

      allow(compactor).to receive(:should_compact?).and_return(true)
      allow(compactor).to receive(:compact).and_return(["Summary", []])

      provider = MockProvider.new
      original_ctx = LLM::Context.new(provider, tools: [], stream: stream)
      prompt = original_ctx.prompt { |p| p.system("sys"); p.user("hello") }
      original_ctx.talk(prompt)

      env = build_env(
        context: original_ctx,
        provider: provider,
        streaming: true,
        callbacks: { on_content: callback },
      )
      middleware_with_stream.call(env)

      new_ctx = env[:context]

      # Simulate what happens next in the orchestrator loop:
      # LLMCall calls new_ctx.talk(tool_results) which should use the stream.
      # If the stream is missing, on_content never fires and content is lost.
      #
      # We can't easily trigger a real streaming call here, but we CAN verify
      # the stream is wired up so that the LLM provider will receive it.
      ctx_params = new_ctx.instance_variable_get(:@params)
      expect(ctx_params).to have_key(:stream),
        "Rebuilt context is missing :stream in @params. " \
        "LLMCall will skip the on_content fallback because env[:streaming] is true, " \
        "so content from the next LLM call will be silently dropped."
    end
  end
end
