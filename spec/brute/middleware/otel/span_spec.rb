# frozen_string_literal: true

RSpec.describe Brute::Middleware::OTel::Span do
  let(:response) { MockResponse.new(content: "hello from LLM") }
  let(:inner_app) { ->(_env) { response } }
  let(:middleware) { described_class.new(inner_app) }

  context "when OpenTelemetry::SDK is not defined" do
    it "passes through to the inner app without touching env[:span]" do
      hide_const("OpenTelemetry::SDK") if defined?(OpenTelemetry::SDK)

      env = build_env
      result = middleware.call(env)

      expect(result).to eq(response)
      expect(env[:span]).to be_nil
    end
  end

  context "when OpenTelemetry::SDK is defined" do
    let(:span) { mock_span }
    let(:tracer) { double("tracer") }
    let(:tracer_provider) { double("tracer_provider", tracer: tracer) }

    before do
      stub_const("OpenTelemetry::SDK", Module.new)
      stub_const("OpenTelemetry::Trace::Status", Class.new {
        def self.error(msg) = new(msg)
        def initialize(msg = nil) = nil
      })

      allow(tracer).to receive(:in_span) do |_name, **_opts, &block|
        block.call(span)
      end

      allow(::OpenTelemetry).to receive(:tracer_provider).and_return(tracer_provider)

      # Clear cached tracer from previous examples
      middleware.instance_variable_set(:@tracer, nil)
    end

    it "creates a span and sets env[:span] during the call" do
      captured_span = nil
      app = ->(env) { captured_span = env[:span]; response }
      mw = described_class.new(app)
      env = build_env

      mw.call(env)

      expect(captured_span).to eq(span)
    end

    it "cleans up env[:span] after the call" do
      env = build_env
      middleware.call(env)

      expect(env[:span]).to be_nil
    end

    it "passes the response through" do
      env = build_env
      result = middleware.call(env)

      expect(result).to eq(response)
    end

    it "creates a span with the tracer" do
      env = build_env
      middleware.call(env)

      expect(tracer).to have_received(:in_span).with(
        anything,
        hash_including(
          attributes: hash_including(
            "brute.provider" => anything,
            "brute.streaming" => false,
            "brute.context_messages" => anything
          ),
          kind: :internal
        )
      )
    end

    it "records exceptions on the span and re-raises" do
      error = RuntimeError.new("LLM exploded")
      app = ->(_env) { raise error }
      mw = described_class.new(app)
      env = build_env

      expect { mw.call(env) }.to raise_error(RuntimeError, "LLM exploded")
      expect(span).to have_received(:record_exception).with(error)
      expect(span).to have_received(:status=)
    end

    it "cleans up env[:span] even on error" do
      app = ->(_env) { raise "boom" }
      mw = described_class.new(app)
      env = build_env

      expect { mw.call(env) }.to raise_error(RuntimeError)
      expect(env[:span]).to be_nil
    end
  end
end
