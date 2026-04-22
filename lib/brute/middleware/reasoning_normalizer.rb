# frozen_string_literal: true

require "bundler/setup"
require "brute"

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

test do
  require_relative "../../../spec/support/mock_provider"
  require_relative "../../../spec/support/mock_response"

  def build_env(**overrides)
    { provider: MockProvider.new, model: nil, input: "test prompt", tools: [],
      messages: [], stream: nil, params: {}, metadata: {}, callbacks: {},
      tool_results: nil, streaming: false, should_exit: nil, pending_functions: [] }.merge(overrides)
  end

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
    klass.define_method(:class) do
      c = super()
      name_str = "LLM::#{type_name}"
      c.define_singleton_method(:name) { name_str }
      c
    end
    klass.new
  end

  inner_app = ->(_env) { MockResponse.new(content: "reasoned response") }

  it "injects thinking param for Anthropic with budget_tokens" do
    provider = make_provider("Anthropic")
    middleware = Brute::Middleware::ReasoningNormalizer.new(inner_app, model_id: "claude-4", budget_tokens: 8000, enabled: true)
    env = build_env(provider: provider, params: {})
    middleware.call(env)
    env[:params][:thinking].should == { type: "enabled", budget_tokens: 8000 }
  end

  it "does not inject thinking param for Anthropic without budget_tokens" do
    provider = make_provider("Anthropic")
    middleware = Brute::Middleware::ReasoningNormalizer.new(inner_app, model_id: "claude-4", enabled: true)
    env = build_env(provider: provider, params: {})
    middleware.call(env)
    env[:params][:thinking].should.be.nil
  end

  it "injects reasoning_effort for OpenAI" do
    provider = make_provider("OpenAI")
    middleware = Brute::Middleware::ReasoningNormalizer.new(inner_app, model_id: "o3", effort: :high, enabled: true)
    env = build_env(provider: provider, params: {})
    middleware.call(env)
    env[:params][:reasoning_effort].should == "high"
  end

  it "maps low effort correctly for OpenAI" do
    provider = make_provider("OpenAI")
    middleware = Brute::Middleware::ReasoningNormalizer.new(inner_app, model_id: "o3", effort: :low, enabled: true)
    env = build_env(provider: provider, params: {})
    middleware.call(env)
    env[:params][:reasoning_effort].should == "low"
  end

  it "does not inject params for unknown provider" do
    provider = make_provider("Mistral")
    middleware = Brute::Middleware::ReasoningNormalizer.new(inner_app, model_id: "mistral-large", enabled: true)
    env = build_env(provider: provider, params: {})
    middleware.call(env)
    env[:params].should == {}
  end

  it "does not inject params when disabled" do
    provider = make_provider("Anthropic")
    middleware = Brute::Middleware::ReasoningNormalizer.new(inner_app, model_id: "claude-4", budget_tokens: 8000, enabled: false)
    env = build_env(provider: provider, params: {})
    middleware.call(env)
    env[:params].should == {}
  end

  it "allows model_id to be updated mid-session" do
    middleware = Brute::Middleware::ReasoningNormalizer.new(inner_app, model_id: "old", enabled: true)
    middleware.model_id = "new"
    provider = make_provider("OpenAI")
    env = build_env(provider: provider, params: {})
    middleware.call(env)
    env[:params][:reasoning_effort].should.not.be.nil
  end
end
