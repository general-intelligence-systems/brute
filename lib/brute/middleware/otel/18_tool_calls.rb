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

  turn = nil
  build_turn = -> {
    return turn if turn

    pipeline = Brute::Middleware::Stack.new do
      use Brute::Middleware::OTel::ToolCalls
      run ->(_env) { MockResponse.new(content: "here's my plan") }
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
    turn.result.content.should == "here's my plan"
  end
end
