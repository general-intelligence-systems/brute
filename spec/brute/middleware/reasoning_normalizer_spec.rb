# frozen_string_literal: true

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

    # Just verifying it doesn't crash with the new model — the model_id setter works
    expect(env[:params][:reasoning_effort]).not_to be_nil
  end
end
