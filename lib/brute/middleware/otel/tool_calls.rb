# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    module OTel
      # Records tool calls the LLM requested as span events.
      #
      # Runs POST-call: after the LLM responds, inspects ctx.functions
      # for any tool calls the model wants to make, and adds a span event
      # for each one with the tool name, call ID, and arguments.
      #
      class ToolCalls < Base
        def call(env)
          response = @app.call(env)

          span = env[:span]
          if span
            functions = env[:pending_functions]
            if functions && !functions.empty?
              span.set_attribute("brute.tool_calls.count", functions.size)

              functions.each do |fn|
                attrs = {
                  "tool.name" => fn.name.to_s,
                  "tool.id" => fn.id.to_s,
                }
                args = fn.arguments
                attrs["tool.arguments"] = args.to_json if args
                span.add_event("tool_call", attributes: attrs)
              end
            end
          end

          response
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
    response = MockResponse.new(content: "here's my plan")
    middleware = Brute::Middleware::OTel::ToolCalls.new(->(_env) { response })
    result = middleware.call(build_env)
    result.should == response
  end

  it "passes through without error when span is nil with pending functions" do
    response = MockResponse.new(content: "here's my plan")
    fn = Struct.new(:name, :id, :arguments, keyword_init: true).new(name: "fs_read", id: "tc_001", arguments: { "path" => "/tmp" })
    middleware = Brute::Middleware::OTel::ToolCalls.new(->(_env) { response })
    result = middleware.call(build_env(pending_functions: [fn]))
    result.should == response
  end
end
