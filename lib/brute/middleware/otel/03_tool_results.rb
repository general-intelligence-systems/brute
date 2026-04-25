# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    module OTel
      # Records tool results being sent back to the LLM as span events.
      #
      # Runs PRE-call: when env[:tool_results] is present, the agent loop
      # is sending tool execution results back to the LLM. Each result gets
      # a span event with the tool name and success/error status.
      #
      class ToolResults < Base
        def call(env)
          span = env[:span]

          if span && (results = env[:tool_results])
            span.set_attribute("brute.tool_results.count", results.size)

            results.each do |name, value|
              error = value.is_a?(Hash) && value[:error]
              attrs = { "tool.name" => name.to_s }
              if error
                attrs["tool.status"] = "error"
                attrs["tool.error"] = value[:error].to_s
              else
                attrs["tool.status"] = "ok"
              end
              span.add_event("tool_result", attributes: attrs)
            end
          end

          @app.call(env)
        end
      end
    end
  end
end

test do
  require_relative "../../../../spec/support/mock_provider"
  require_relative "../../../../spec/support/mock_response"

  def build_env(**overrides)
    { provider: MockProvider.new, model: nil, input: "test prompt", tools: [],
      messages: [], stream: nil, params: {}, metadata: {}, callbacks: {},
      tool_results: nil, streaming: false, should_exit: nil, pending_functions: [] }.merge(overrides)
  end

  it "passes the response through unchanged" do
    response = MockResponse.new(content: "processed")
    middleware = Brute::Middleware::OTel::ToolResults.new(->(_env) { response })
    result = middleware.call(build_env)
    result.should == response
  end

  it "passes through without error when span is nil" do
    response = MockResponse.new(content: "processed")
    middleware = Brute::Middleware::OTel::ToolResults.new(->(_env) { response })
    result = middleware.call(build_env(tool_results: [["fs_read", { content: "data" }]]))
    result.should == response
  end
end
