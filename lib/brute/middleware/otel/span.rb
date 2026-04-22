# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Middleware
    module OTel
      # Outermost OTel middleware. Creates a span per LLM pipeline call
      # and passes it through env[:span] for inner OTel middlewares to
      # decorate with events and attributes.
      #
      # When opentelemetry-sdk is not loaded, this is a pure pass-through.
      #
      # Pipeline position: outermost (wraps everything including retries).
      #
      #   use Brute::Middleware::OTel::Span
      #   use Brute::Middleware::OTel::ToolResults
      #   use Brute::Middleware::OTel::ToolCalls
      #   use Brute::Middleware::OTel::TokenUsage
      #   # ... existing middleware ...
      #   run Brute::Middleware::LLMCall.new
      #
      class Span < Base
        def call(env)
          return @app.call(env) unless defined?(::OpenTelemetry::SDK)

          provider_name = provider_type(env[:provider])
          model = env[:model] || (env[:provider].default_model rescue nil)
          span_name = model ? "llm.call #{model}" : "llm.call"

          attributes = {
            "brute.provider" => provider_name,
            "brute.streaming" => !!env[:streaming],
            "brute.context_messages" => env[:messages].size,
          }
          attributes["brute.model"] = model.to_s if model
          attributes["brute.session_id"] = env[:metadata][:session_id].to_s if env.dig(:metadata, :session_id)

          tracer.in_span(span_name, attributes: attributes, kind: :internal) do |span|
            env[:span] = span
            response = @app.call(env)

            # Record response model if it differs from request model
            resp_model = begin; response.model; rescue; nil; end
            span.set_attribute("brute.response_model", resp_model.to_s) if resp_model && resp_model != model

            response
          rescue ::StandardError => e
            span.record_exception(e)
            span.status = ::OpenTelemetry::Trace::Status.error(e.message)
            raise
          ensure
            env.delete(:span)
          end
        end

        private

        def tracer
          @tracer ||= ::OpenTelemetry.tracer_provider.tracer("brute", Brute::VERSION)
        end

        def provider_type(provider)
          name = provider.class.name.to_s.downcase
          if name.include?("anthropic") then "anthropic"
          elsif name.include?("openai") then "openai"
          elsif name.include?("google") || name.include?("gemini") then "google"
          elsif name.include?("deepseek") then "deepseek"
          elsif name.include?("ollama") then "ollama"
          elsif name.include?("xai") then "xai"
          else "unknown"
          end
        end
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../../spec/spec_helper"

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
end
