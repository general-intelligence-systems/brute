# frozen_string_literal: true

require "bundler/setup"
require "brute"

#require 'brute/middleware/otel/01_span'
#require 'brute/middleware/otel/03_tool_results'
#require 'brute/middleware/otel/18_tool_calls'
#require 'brute/middleware/otel/10_token_usage'

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
