# frozen_string_literal: true

module Brute
  module Middleware
    # Guards against tool-only LLM responses where the assistant message
    # is dropped from the context buffer.
    #
    # When the LLM responds with only tool_use blocks (no text), llm.rb's
    # response adapter produces empty choices. Context#talk appends nil,
    # BufferNilGuard strips it, and the assistant message carrying tool_use
    # blocks is lost. This causes "unexpected tool_use_id" on the next call
    # because tool_result references a tool_use that's missing from the buffer.
    #
    # This middleware runs post-call and ensures every pending tool_use ID
    # is covered by an assistant message in the buffer. It handles three
    # cases:
    #
    #   1. ctx.functions is non-empty and the assistant message exists → no-op
    #   2. ctx.functions is non-empty but the assistant message is missing
    #      (or has different IDs) → inject synthetic message
    #   3. ctx.functions is empty (nil-choice bug) but the stream recorded
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
        # stream's recorded metadata (fallback for nil-choice bug).
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
            stream.clear_pending!
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
