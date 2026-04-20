# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Middleware
    # Checks context size after each LLM call and triggers compaction
    # when thresholds are exceeded.
    #
    # Runs POST-call: inspects message count and token usage from the
    # response. If compaction is needed, summarizes older messages and
    # rebuilds the context with the summary + recent messages.
    #
    class CompactionCheck < Base
      def initialize(app, compactor:, system_prompt:, tools:, stream: nil)
        super(app)
        @compactor = compactor
        @system_prompt = system_prompt
        @tools = tools
        @stream = stream
      end

      def call(env)
        response = @app.call(env)

        ctx = env[:context]
        messages = ctx.messages.to_a.compact
        usage = ctx.usage rescue nil

        if @compactor.should_compact?(messages, usage: usage)
          result = @compactor.compact(messages)
          if result
            summary_text, _recent = result
            rebuild_context!(env, summary_text)
            env[:metadata][:compaction] = {
              messages_before: messages.size,
              timestamp: Time.now.iso8601,
            }
          end
        end

        response
      end

      private

      def rebuild_context!(env, summary_text)
        provider = env[:provider]
        ctx_opts = { tools: @tools }
        ctx_opts[:stream] = @stream if @stream
        new_ctx = LLM::Context.new(provider, **ctx_opts)
        prompt = new_ctx.prompt do |p|
          p.system @system_prompt
          p.user "[Previous conversation summary]\n\n#{summary_text}"
        end
        new_ctx.talk(prompt)
        env[:context] = new_ctx
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

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
      prompt = ctx.prompt { |p| p.system("sys"); p.user("hello") }
      ctx.talk(prompt)

      env = build_env(context: ctx, provider: provider)
      middleware.call(env)

      expect(env[:metadata][:compaction]).to include(:messages_before, :timestamp)
      expect(env[:context]).not_to equal(ctx)
    end

    it "handles compactor returning nil gracefully" do
      allow(compactor).to receive(:should_compact?).and_return(true)
      allow(compactor).to receive(:compact).and_return(nil)

      env = build_env
      original_ctx = env[:context]

      middleware.call(env)

      expect(env[:context]).to equal(original_ctx)
      expect(env[:metadata][:compaction]).to be_nil
    end

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

        ctx_params = new_ctx.instance_variable_get(:@params)
        expect(ctx_params).to have_key(:stream),
          "Rebuilt context is missing :stream in @params. " \
          "LLMCall will skip the on_content fallback because env[:streaming] is true, " \
          "so content from the next LLM call will be silently dropped."
      end
    end
  end
end
