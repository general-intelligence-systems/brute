# frozen_string_literal: true

# Shared helpers for middleware specs.
#
# Every middleware follows the same call(env) contract, so we can share
# env construction and mock inner-app factories across all specs.
module MiddlewareHelpers
  # Build a default env hash suitable for most middleware tests.
  # Override any key by passing keyword arguments.
  def build_env(**overrides)
    provider = overrides.delete(:provider) || MockProvider.new
    context  = overrides.delete(:context)  || LLM::Context.new(provider, tools: [])

    {
      context:      context,
      provider:     provider,
      input:        overrides.delete(:input) || "test prompt",
      tools:        overrides.delete(:tools) || [],
      params:       overrides.delete(:params) || {},
      metadata:     overrides.delete(:metadata) || {},
      callbacks:    overrides.delete(:callbacks) || {},
      tool_results: overrides.delete(:tool_results),
      streaming:    overrides.delete(:streaming) || false,
    }.merge(overrides)
  end

  # A mock inner app (lambda) that records calls and returns a canned response.
  # Returns [inner_app, calls_array] so specs can inspect what was passed in.
  def mock_inner_app(response: nil)
    response ||= MockResponse.new(content: "inner response")
    calls = []
    app = ->(env) { calls << env; response }
    [app, calls]
  end

  # An inner app that raises on the first N calls, then succeeds.
  def flaky_inner_app(error_class, message: "transient error", fail_count: 1, response: nil)
    response ||= MockResponse.new(content: "recovered")
    attempt = 0
    ->(env) do
      attempt += 1
      raise error_class, message if attempt <= fail_count
      response
    end
  end

  # An inner app that always raises.
  def failing_inner_app(error_class, message: "boom")
    ->(_env) { raise error_class, message }
  end

  # A mock OTel span that records set_attribute, add_event, record_exception,
  # and status= calls for assertion.
  def mock_span
    span = double("OTel::Span")
    allow(span).to receive(:set_attribute)
    allow(span).to receive(:add_event)
    allow(span).to receive(:record_exception)
    allow(span).to receive(:status=)
    span
  end
end

RSpec.configure do |config|
  config.include MiddlewareHelpers
end
