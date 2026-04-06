# frozen_string_literal: true

module Brute
  module Middleware
    # OpenTelemetry instrumentation for the LLM pipeline.
    #
    # Each middleware is independent and communicates through env[:span].
    # OTel::Span must be outermost — it creates the span. The rest
    # decorate it with events and attributes from their position in the
    # pipeline.
    #
    # All middlewares are no-ops when opentelemetry-sdk is not loaded.
    #
    # Usage in pipeline:
    #
    #   use Brute::Middleware::OTel::Span
    #   use Brute::Middleware::OTel::ToolResults
    #   use Brute::Middleware::OTel::ToolCalls
    #   use Brute::Middleware::OTel::TokenUsage
    #
    module OTel
    end
  end
end

require_relative "otel/span"
require_relative "otel/tool_results"
require_relative "otel/tool_calls"
require_relative "otel/token_usage"
