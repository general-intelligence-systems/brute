# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

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

require_relative "otel/01_span"
require_relative "otel/03_tool_results"
require_relative "otel/18_tool_calls"
require_relative "otel/10_token_usage"
