# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    module OTel
      # Outermost OTel middleware. Creates a span per LLM stack call
      # and passes it through env[:span] for inner OTel middlewares to
      # decorate with events and attributes.
      #
      # When opentelemetry-sdk is not loaded, this is a pure pass-through.
      #
      # Stack position: outermost (wraps everything including retries).
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

test do
  require_relative "../../../../spec/support/mock_provider"
  require_relative "../../../../spec/support/mock_response"

  turn = nil
  build_turn = -> {
    return turn if turn

    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::OTel::Span
      run ->(_env) { MockResponse.new(content: "hello from LLM") }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
  }

  it "passes through when OpenTelemetry::SDK is not defined" do
    build_turn.call
    turn.result.content.should == "hello from LLM"
  end

  it "env[:span] is nil when OTel is not defined" do
    build_turn.call
    turn.env[:span].should.be.nil
  end
end
