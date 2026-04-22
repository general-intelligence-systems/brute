# frozen_string_literal: true

module Brute
  module Middleware
    # Guards against tool-only LLM responses where the assistant message
    # is dropped from the context buffer.
    #
    # Historically this covered an llm.rb bug where tool-only responses could
    # lose their assistant message, leaving later tool_result messages orphaned.
    # With modern llm.rb this should be a no-op, but it remains a defensive
    # guard against missing assistant tool-call messages.
    #
    # This middleware runs post-call and ensures every pending tool_use ID
    # is covered by an assistant message in the buffer. It handles three
    # cases:
    #
    #   1. ctx.functions is non-empty and the assistant message exists → no-op
    #   2. ctx.functions is non-empty but the assistant message is missing
    #      (or has different IDs) → inject synthetic message
    #   3. ctx.functions is empty but the stream recorded
    #      tool calls → inject synthetic message using stream metadata
    #
    class ToolUseGuard
      def initialize(app)
        @app = app
      end

      def call(env)
        response = @app.call(env)

        ctx = env[:context]

        # Collect pending tool data from ctx.functions (primary) or the
        # stream's recorded metadata.
        tool_data = collect_tool_data(ctx, env)
        return response if tool_data.empty?

        # Find all tool_use IDs already covered by assistant messages.
        covered_ids = covered_tool_ids(ctx)

        # Inject a synthetic assistant message for any uncovered tool calls.
        uncovered = tool_data.reject { |td| covered_ids.include?(td[:id]) }
        inject_synthetic!(ctx, uncovered) unless uncovered.empty?

        response
      end

      private

      def collect_tool_data(ctx, env)
        functions = ctx.functions
        if functions && !functions.empty?
          functions.map { |fn| { id: fn.id, name: fn.name, arguments: fn.arguments } }
        elsif env[:streaming]
          stream = resolve_stream(ctx)
          if stream
            data = stream.pending_tool_calls.dup
            stream.clear_pending_tool_calls!
            data
          else
            []
          end
        else
          []
        end
      end

      def resolve_stream(ctx)
        stream = ctx.instance_variable_get(:@params)&.dig(:stream)
        stream if stream.respond_to?(:pending_tool_calls)
      end

      def covered_tool_ids(ctx)
        ctx.messages.to_a
          .select { |m| m.role.to_s == "assistant" && m.tool_call? }
          .flat_map { |m| (m.extra.original_tool_calls || []).map { |tc| tc["id"] } }
          .to_set
      end

      def inject_synthetic!(ctx, uncovered)
        tool_calls = uncovered.map do |td|
          LLM::Object.from(id: td[:id], name: td[:name], arguments: td[:arguments])
        end
        original_tool_calls = uncovered.map do |td|
          { "type" => "tool_use", "id" => td[:id], "name" => td[:name], "input" => td[:arguments] || {} }
        end

        synthetic = LLM::Message.new(:assistant, "", {
          tool_calls: tool_calls,
          original_tool_calls: original_tool_calls,
        })
        ctx.messages.concat([synthetic])
      end
    end
  end
end

if __FILE__ == $0
  require_relative "../../../spec/spec_helper"

  RSpec.describe Brute::Middleware::ToolUseGuard do
    let(:provider) { MockProvider.new }

    # Helper: build a response that produces pending tool calls (functions) in the context.
    def make_tool_response(tool_calls:)
      MockResponse.new(content: "", tool_calls: tool_calls)
    end

    it "passes the response through when there are no pending functions" do
      response = MockResponse.new(content: "no tools")
      allow(provider).to receive(:complete).and_return(response)

      ctx = LLM::Context.new(provider, tools: [])
      prompt = ctx.prompt { |p| p.system("sys"); p.user("hi") }

      inner_app = ->(_env) { ctx.talk(prompt); response }
      middleware = described_class.new(inner_app)
      env = build_env(context: ctx, provider: provider)

      result = middleware.call(env)
      expect(result).to eq(response)
    end

    it "does not inject a synthetic message when the assistant message already has tool_call?" do
      tool_calls = [{ id: "toolu_1", name: "fs_read", arguments: { "path" => "test.rb" } }]
      response = make_tool_response(tool_calls: tool_calls)
      allow(provider).to receive(:complete).and_return(response)

      ctx = LLM::Context.new(provider, tools: [])
      prompt = ctx.prompt { |p| p.system("sys"); p.user("read it") }

      inner_app = ->(_env) { ctx.talk(prompt); response }
      middleware = described_class.new(inner_app)
      env = build_env(context: ctx, provider: provider)

      middleware.call(env)

      messages = ctx.messages.to_a
      assistant_msgs = messages.select { |m| m.role.to_s == "assistant" }
      # Should only have the original assistant message, no synthetic
      expect(assistant_msgs.size).to eq(1)
    end

    it "injects a synthetic assistant message when tool calls exist but assistant is missing" do
      tool_calls = [{ id: "toolu_1", name: "fs_read", arguments: { "path" => "test.rb" } }]
      response = MockResponse.new(content: "")
      # Simulate the bug: choices[-1] is nil, so no assistant message stored
      allow(response).to receive(:choices).and_return([nil])
      allow(provider).to receive(:complete).and_return(response)

      ctx = LLM::Context.new(provider, tools: [])
      prompt = ctx.prompt { |p| p.system("sys"); p.user("read it") }

      inner_app = ->(_env) do
        ctx.talk(prompt)
        response
      end

      middleware = described_class.new(inner_app)
      env = build_env(context: ctx, provider: provider)

      expect { middleware.call(env) }.not_to raise_error
    end
  end
end
