# frozen_string_literal: true

require "logger"
require "stringio"

RSpec.describe Brute::Middleware::Tracing do
  let(:response) { MockResponse.new(content: "traced response") }
  let(:inner_app) { ->(_env) { response } }
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }
  let(:middleware) { described_class.new(inner_app, logger: logger) }

  it "passes the response through unchanged" do
    env = build_env(tool_results: nil)
    result = middleware.call(env)
    expect(result).to eq(response)
  end

  it "populates env[:metadata][:timing] with all required keys" do
    env = build_env(tool_results: nil)
    middleware.call(env)

    timing = env[:metadata][:timing]
    expect(timing).to include(
      :total_elapsed,
      :total_llm_elapsed,
      :llm_call_count,
      :last_call_elapsed
    )
    expect(timing[:llm_call_count]).to eq(1)
    expect(timing[:last_call_elapsed]).to be >= 0
    expect(timing[:total_llm_elapsed]).to be >= 0
  end

  it "resets turn timing when tool_results is nil (new turn)" do
    env = build_env(tool_results: nil)
    middleware.call(env)
    first_elapsed = env[:metadata][:timing][:total_llm_elapsed]

    # Simulate continuation within the same turn (tool_results present)
    env[:tool_results] = [["read", { content: "file data" }]]
    middleware.call(env)

    expect(env[:metadata][:timing][:llm_call_count]).to eq(2)
    expect(env[:metadata][:timing][:total_llm_elapsed]).to be >= first_elapsed
  end

  it "accumulates call count across multiple calls" do
    env = build_env(tool_results: nil)
    middleware.call(env)
    env[:tool_results] = [["read", {}]]
    middleware.call(env)
    middleware.call(env)

    expect(env[:metadata][:timing][:llm_call_count]).to eq(3)
  end

  it "logs debug and info messages" do
    env = build_env(tool_results: nil)
    middleware.call(env)

    log_text = log_output.string
    expect(log_text).to include("LLM call #1")
    expect(log_text).to include("LLM response #1")
  end
end
