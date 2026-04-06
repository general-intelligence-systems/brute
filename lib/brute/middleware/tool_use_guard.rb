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
    # This middleware runs post-call and injects a synthetic assistant message
    # when tool calls exist but no assistant message was recorded.
    class ToolUseGuard
      def initialize(app)
        @app = app
      end

      def call(env)
        response = @app.call(env)

        ctx = env[:context]
        functions = ctx.functions

        # If there are pending tool calls, ensure the buffer has an assistant
        # message with tool_use blocks.
        if functions && !functions.empty?
          messages = ctx.messages.to_a
          last_assistant = messages.reverse.find { |m| m.role.to_s == "assistant" }

          unless last_assistant&.tool_call?
            # Build a synthetic assistant message with the tool_use data
            tool_calls = functions.map do |fn|
              LLM::Object.from(id: fn.id, name: fn.name, arguments: fn.arguments)
            end
            original_tool_calls = functions.map do |fn|
              { "type" => "tool_use", "id" => fn.id, "name" => fn.name, "input" => fn.arguments || {} }
            end

            synthetic = LLM::Message.new(:assistant, "", {
              tool_calls: tool_calls,
              original_tool_calls: original_tool_calls,
            })
            ctx.messages.concat([synthetic])
          end
        end

        response
      end
    end
  end
end
