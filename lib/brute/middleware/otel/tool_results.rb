# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

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

if __FILE__ == $0
  require_relative "../../../../spec/spec_helper"

  RSpec.describe Brute::Middleware::OTel::ToolResults do
    let(:response) { MockResponse.new(content: "processed") }
    let(:inner_app) { ->(_env) { response } }
    let(:middleware) { described_class.new(inner_app) }

    it "passes the response through unchanged" do
      env = build_env
      result = middleware.call(env)
      expect(result).to eq(response)
    end

    context "when env[:span] is nil" do
      it "passes through without error" do
        results = [["fs_read", { content: "data" }]]
        env = build_env(tool_results: results)

        result = middleware.call(env)
        expect(result).to eq(response)
      end
    end

    context "when env[:span] is present" do
      let(:span) { mock_span }

      it "does nothing when tool_results is nil" do
        env = build_env(span: span, tool_results: nil)
        middleware.call(env)

        expect(span).not_to have_received(:add_event)
        expect(span).not_to have_received(:set_attribute)
      end

      it "records a tool_result event per result" do
        results = [
          ["fs_read", { content: "file data" }],
          ["shell", { output: "ok" }],
        ]
        env = build_env(span: span, tool_results: results)
        middleware.call(env)

        expect(span).to have_received(:set_attribute).with("brute.tool_results.count", 2)
        expect(span).to have_received(:add_event).with(
          "tool_result",
          attributes: hash_including("tool.name" => "fs_read", "tool.status" => "ok")
        )
        expect(span).to have_received(:add_event).with(
          "tool_result",
          attributes: hash_including("tool.name" => "shell", "tool.status" => "ok")
        )
      end

      it "records error status and message for failed tool results" do
        results = [
          ["fs_read", { error: "not found" }],
        ]
        env = build_env(span: span, tool_results: results)
        middleware.call(env)

        expect(span).to have_received(:add_event).with(
          "tool_result",
          attributes: hash_including(
            "tool.name" => "fs_read",
            "tool.status" => "error",
            "tool.error" => "not found"
          )
        )
      end

      it "handles a mix of successful and failed results" do
        results = [
          ["fs_read", { content: "ok" }],
          ["shell", { error: "exit code 1" }],
          ["fs_write", { success: true }],
        ]
        env = build_env(span: span, tool_results: results)
        middleware.call(env)

        expect(span).to have_received(:set_attribute).with("brute.tool_results.count", 3)
        expect(span).to have_received(:add_event).exactly(3).times
      end
    end
  end
end
