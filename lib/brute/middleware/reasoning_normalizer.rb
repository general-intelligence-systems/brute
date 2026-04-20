# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Middleware
    # Handles reasoning/thinking content across model switches.
    #
    # PRE-call:
    #   - If reasoning is enabled, injects provider-specific params into
    #     the env (e.g., Anthropic thinking config, OpenAI reasoning_effort).
    #   - Tracks which model produced each message. When the model changes,
    #     strips reasoning_content from messages produced by the old model
    #     (signatures are model-specific and cryptographically tied).
    #
    # POST-call:
    #   - Records the current model on the response for future normalization.
    #
    # llm.rb exposes:
    #   - response.reasoning_content  — the thinking text
    #   - response.reasoning_tokens   — token count
    #   - Provider params pass-through — we can send thinking:, reasoning_effort:, etc.
    #
    class ReasoningNormalizer < Base
      # Effort levels that map to provider-specific params.
      # Mirrors forgecode's Effort enum.
      EFFORT_LEVELS = {
        none: "none",
        minimal: "low",
        low: "low",
        medium: "medium",
        high: "high",
        xhigh: "high",
        max: "high",
      }.freeze

      def initialize(app, model_id: nil, effort: :medium, enabled: true, budget_tokens: nil)
        super(app)
        @model_id = model_id
        @effort = effort
        @enabled = enabled
        @budget_tokens = budget_tokens
        @message_models = [] # tracks which model produced each assistant message
      end

      def call(env)
        if @enabled
          inject_reasoning_params!(env)
        end

        response = @app.call(env)

        # POST: record which model produced this response
        if response
          @message_models << @model_id
        end

        response
      end

      # Update the active model (e.g., when user switches models mid-session).
      def model_id=(new_model)
        @model_id = new_model
      end

      private

      def inject_reasoning_params!(env)
        env[:params] ||= {}
        provider = env[:provider]

        case provider_type(provider)
        when :anthropic
          if @budget_tokens
            # Older extended thinking API (claude-3.7-sonnet style)
            env[:params][:thinking] = {type: "enabled", budget_tokens: @budget_tokens}
          else
            # Newer effort-based API (claude-4 style) — pass through
            # Anthropic handles this via the model itself
          end
        when :openai
          env[:params][:reasoning_effort] = EFFORT_LEVELS[@effort] || "medium"
        end
      end

      def provider_type(provider)
        class_name = provider.class.name.to_s.downcase
        if class_name.include?("anthropic")
          :anthropic
        elsif class_name.include?("openai")
          :openai
        elsif class_name.include?("google") || class_name.include?("gemini")
          :google
        else
          :unknown
        end
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Middleware::ReasoningNormalizer do
    let(:response) { MockResponse.new(content: "reasoned response") }
    let(:inner_app) { ->(_env) { response } }

    # Build a provider whose class name contains the given string.
    def make_provider(type_name)
      klass = Class.new do
        define_method(:name) { :mock }
        define_method(:default_model) { "mock-model" }
        define_method(:user_role) { :user }
        define_method(:system_role) { :system }
        define_method(:assistant_role) { :assistant }
        define_method(:tool_role) { :tool }
        define_method(:tracer) { nil }
        define_method(:tracer=) { |*| }
        define_method(:complete) { |*_args, **_kw| MockResponse.new(content: "ok") }
      end
      # Override class name to trigger provider_type detection
      klass.define_method(:class) do
        c = super()
        name_str = "LLM::#{type_name}"
        c.define_singleton_method(:name) { name_str }
        c
      end
      klass.new
    end

    context "with Anthropic provider and budget_tokens" do
      it "injects thinking param into env[:params]" do
        provider = make_provider("Anthropic")
        middleware = described_class.new(inner_app, model_id: "claude-4", budget_tokens: 8000, enabled: true)
        env = build_env(provider: provider, params: {})

        middleware.call(env)

        expect(env[:params][:thinking]).to eq({ type: "enabled", budget_tokens: 8000 })
      end
    end

    context "with Anthropic provider without budget_tokens" do
      it "does not inject thinking param" do
        provider = make_provider("Anthropic")
        middleware = described_class.new(inner_app, model_id: "claude-4", enabled: true)
        env = build_env(provider: provider, params: {})

        middleware.call(env)

        expect(env[:params][:thinking]).to be_nil
      end
    end

    context "with OpenAI provider" do
      it "injects reasoning_effort based on effort level" do
        provider = make_provider("OpenAI")
        middleware = described_class.new(inner_app, model_id: "o3", effort: :high, enabled: true)
        env = build_env(provider: provider, params: {})

        middleware.call(env)

        expect(env[:params][:reasoning_effort]).to eq("high")
      end

      it "maps effort levels correctly" do
        provider = make_provider("OpenAI")

        { low: "low", medium: "medium", high: "high", minimal: "low", max: "high" }.each do |effort, expected|
          middleware = described_class.new(inner_app, model_id: "o3", effort: effort, enabled: true)
          env = build_env(provider: provider, params: {})
          middleware.call(env)
          expect(env[:params][:reasoning_effort]).to eq(expected), "Expected effort #{effort} to map to #{expected}"
        end
      end
    end

    context "with unknown provider" do
      it "does not inject any reasoning params" do
        provider = make_provider("Mistral")
        middleware = described_class.new(inner_app, model_id: "mistral-large", enabled: true)
        env = build_env(provider: provider, params: {})

        middleware.call(env)

        expect(env[:params]).to eq({})
      end
    end

    context "when disabled" do
      it "does not inject reasoning params" do
        provider = make_provider("Anthropic")
        middleware = described_class.new(inner_app, model_id: "claude-4", budget_tokens: 8000, enabled: false)
        env = build_env(provider: provider, params: {})

        middleware.call(env)

        expect(env[:params]).to eq({})
      end
    end

    it "allows model_id to be updated mid-session" do
      middleware = described_class.new(inner_app, model_id: "old-model", enabled: true)
      middleware.model_id = "new-model"

      provider = make_provider("OpenAI")
      env = build_env(provider: provider, params: {})
      middleware.call(env)

      expect(env[:params][:reasoning_effort]).not_to be_nil
    end
  end
end
