# frozen_string_literal: true

require "logger"
require "stringio"

RSpec.describe "Middleware Pipeline Integration" do
  let(:provider) { MockProvider.new }
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }
  let(:session) { double("session", save: nil) }
  let(:compactor) { double("compactor", should_compact?: false) }

  # Build pipelines using method chaining instead of instance_eval blocks
  # to avoid scope issues with let variables.

  describe "full orchestrator pipeline" do
    it "passes env through all middleware and returns the response" do
      response = MockResponse.new(content: "integrated response")
      allow(provider).to receive(:complete).and_return(response)

      ctx = LLM::Context.new(provider, tools: [])
      prompt = ctx.prompt { |p| p.system("sys"); p.user("hello") }

      pipeline = Brute::Pipeline.new
      pipeline.use(Brute::Middleware::Tracing, logger: logger)
      pipeline.use(Brute::Middleware::Retry, max_attempts: 3, base_delay: 2)
      pipeline.use(Brute::Middleware::SessionPersistence, session: session)
      pipeline.use(Brute::Middleware::TokenTracking)
      pipeline.use(Brute::Middleware::CompactionCheck, compactor: compactor, system_prompt: "sys", tools: [])
      pipeline.use(Brute::Middleware::ToolErrorTracking)
      pipeline.use(Brute::Middleware::DoomLoopDetection, threshold: 3)
      pipeline.use(Brute::Middleware::ToolUseGuard)
      pipeline.run(Brute::Middleware::LLMCall.new)

      env = {
        context: ctx,
        provider: provider,
        input: prompt,
        tools: [],
        params: {},
        metadata: {},
        callbacks: {},
        tool_results: nil,
        streaming: false,
      }

      result = pipeline.call(env)

      # Response returned
      expect(result).not_to be_nil

      # Timing metadata populated by Tracing
      expect(env[:metadata][:timing]).to include(:llm_call_count, :total_llm_elapsed)

      # Token metadata populated by TokenTracking
      expect(env[:metadata][:tokens]).to include(:total_input, :total_output, :call_count)

      # Session save called
      expect(session).to have_received(:save)

      # Logging happened
      expect(log_output.string).to include("LLM call #1")
    end
  end

  describe "Retry + Tracing combo" do
    it "Tracing sees the full elapsed time including retries" do
      call_count = 0
      response = MockResponse.new(content: "recovered")

      allow(provider).to receive(:complete) do |*_args|
        call_count += 1
        raise LLM::RateLimitError, "rate limited" if call_count <= 1
        response
      end

      ctx = LLM::Context.new(provider, tools: [])
      prompt = ctx.prompt { |p| p.system("sys"); p.user("hi") }

      pipeline = Brute::Pipeline.new
      pipeline.use(Brute::Middleware::Tracing, logger: logger)
      pipeline.use(Brute::Middleware::Retry, max_attempts: 3, base_delay: 0)
      pipeline.run(Brute::Middleware::LLMCall.new)

      env = {
        context: ctx,
        provider: provider,
        input: prompt,
        tools: [],
        params: {},
        metadata: {},
        callbacks: {},
        tool_results: nil,
        streaming: false,
      }

      result = pipeline.call(env)

      expect(result).not_to be_nil
      expect(env[:metadata][:timing][:llm_call_count]).to eq(1)
    end
  end

  describe "TokenTracking + SessionPersistence combo" do
    it "session receives save after tokens are tracked" do
      response = MockResponse.new(content: "tracked and saved")
      allow(provider).to receive(:complete).and_return(response)

      ctx = LLM::Context.new(provider, tools: [])
      prompt = ctx.prompt { |p| p.system("sys"); p.user("hi") }

      save_args = []
      allow(session).to receive(:save) { |ctx_arg| save_args << ctx_arg }

      pipeline = Brute::Pipeline.new
      pipeline.use(Brute::Middleware::SessionPersistence, session: session)
      pipeline.use(Brute::Middleware::TokenTracking)
      pipeline.run(Brute::Middleware::LLMCall.new)

      env = {
        context: ctx,
        provider: provider,
        input: prompt,
        tools: [],
        params: {},
        metadata: {},
        callbacks: {},
        tool_results: nil,
        streaming: false,
      }

      pipeline.call(env)

      # Both should have fired
      expect(env[:metadata][:tokens]).to include(:total_input)
      expect(save_args.size).to eq(1)
    end
  end

  describe "Pipeline builder" do
    it "raises when no terminal app is set" do
      pipeline = Brute::Pipeline.new
      pipeline.use(Brute::Middleware::TokenTracking)

      expect { pipeline.call({}) }.to raise_error(RuntimeError, /no terminal app/)
    end
  end
end
