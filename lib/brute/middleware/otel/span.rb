# frozen_string_literal: true

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
          model = begin; env[:context].model; rescue; nil; end
          span_name = model ? "llm.call #{model}" : "llm.call"

          attributes = {
            "brute.provider" => provider_name,
            "brute.streaming" => !!env[:streaming],
            "brute.context_messages" => env[:context].messages.to_a.size,
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
