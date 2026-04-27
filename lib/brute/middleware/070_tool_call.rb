# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    class ToolCall
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)

        if any_pending_tool_calls?(env[:messages].last)

          available_tools = resolve_tools(env[:tools])
          env[:events] << on_tool_call_start_event(pending_tool_calls)

          pending_tool_calls.each do |_id, tool_call|

            tool = available_tools[tool_call.name.to_sym]
            result = tool.call(tool_call.arguments)

            # Coerce to String so RubyLLM::Message doesn't treat Hash results
            # (e.g. Shell's {stdout:, stderr:, exit_code:}) as attachments.
            content = result.is_a?(String) ? result : result.to_s

            env[:events] << { type: :tool_result, data: { name: tool_call.name, content: content } }
            env[:messages] << RubyLLM::Message.new(role: :tool, content: content, tool_call_id: tool_call.id)
          end
        end

        return env
      end

      private

        def any_pending_tool_calls?(message)
          message.tool_call? && pending_tool_calls(message).any?
        end

        def pending_tool_calls(message)
          message.tool_calls.reject { |_id, tc| tc.name == "question" }
        end

        def resolve_tools(tools)
          tools.each_with_object({}) do |tool, hash|
            instance = tool.is_a?(Class) ? tool.new : tool
            hash[instance.name.to_sym] = instance
          end
        end

        def on_tool_call_start_event(pending_tools)
          {
            type: :tool_call_start,
            data: pending_tools.map { |_id, tc|
              {
                name: tc.name,
                call_id: tc.id,
                arguments: tc.arguments
              }
            }
          }
        end
    end
  end
end

test do
  # not implemented
end
