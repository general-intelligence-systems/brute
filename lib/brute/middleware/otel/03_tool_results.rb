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

  turn = nil
  build_turn = -> {
    return turn if turn

    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::OTel::ToolResults
      run ->(_env) { MockResponse.new(content: "processed") }
    end

    turn = Brute::Loop::AgentTurn.perform(
      agent: Brute::Agent.new(provider: MockProvider.new, model: nil, tools: []),
      session: Brute::Store::Session.new,
      pipeline: pipeline,
      input: "hi",
    )
  }

  it "passes the response through unchanged" do
    build_turn.call
    turn.result.content.should == "processed"
  end
end
