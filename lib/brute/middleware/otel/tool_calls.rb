# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

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

if __FILE__ == $0
  require_relative "../../../../spec/spec_helper"

  RSpec.describe Brute::Middleware::OTel::ToolCalls do
    let(:response) { MockResponse.new(content: "here's my plan") }
    let(:inner_app) { ->(_env) { response } }
    let(:middleware) { described_class.new(inner_app) }

    it "passes the response through unchanged" do
      env = build_env
      result = middleware.call(env)
      expect(result).to eq(response)
    end

    context "when env[:span] is nil" do
      it "passes through without error even with pending functions" do
        fn = double("function", name: "fs_read", id: "tc_001", arguments: { "path" => "/tmp" })

        env = build_env(pending_functions: [fn])
        result = middleware.call(env)
        expect(result).to eq(response)
      end
    end

    context "when env[:span] is present" do
      let(:span) { mock_span }

      it "does nothing when there are no pending functions" do
        env = build_env(pending_functions: [], span: span)
        middleware.call(env)

        expect(span).not_to have_received(:add_event)
        expect(span).not_to have_received(:set_attribute)
      end

      it "does nothing when functions is nil" do
        env = build_env(pending_functions: nil, span: span)
        middleware.call(env)

        expect(span).not_to have_received(:add_event)
      end

      it "records a tool_call event per pending function" do
        fn1 = double("function", name: "fs_read", id: "tc_001", arguments: { "path" => "/src/main.rb" })
        fn2 = double("function", name: "shell", id: "tc_002", arguments: { "command" => "rspec" })

        env = build_env(pending_functions: [fn1, fn2], span: span)
        middleware.call(env)

        expect(span).to have_received(:set_attribute).with("brute.tool_calls.count", 2)
        expect(span).to have_received(:add_event).with(
          "tool_call",
          attributes: hash_including(
            "tool.name" => "fs_read",
            "tool.id" => "tc_001"
          )
        )
        expect(span).to have_received(:add_event).with(
          "tool_call",
          attributes: hash_including(
            "tool.name" => "shell",
            "tool.id" => "tc_002"
          )
        )
      end

      it "serializes arguments as JSON" do
        args = { "path" => "/tmp/test.rb", "content" => "puts 'hi'" }
        fn = double("function", name: "fs_write", id: "tc_003", arguments: args)

        env = build_env(pending_functions: [fn], span: span)
        middleware.call(env)

        expect(span).to have_received(:add_event).with(
          "tool_call",
          attributes: hash_including("tool.arguments" => args.to_json)
        )
      end

      it "handles nil arguments" do
        fn = double("function", name: "todo_read", id: "tc_004", arguments: nil)

        env = build_env(pending_functions: [fn], span: span)
        middleware.call(env)

        expect(span).to have_received(:add_event).with(
          "tool_call",
          attributes: { "tool.name" => "todo_read", "tool.id" => "tc_004" }
        )
      end
    end
  end
end
