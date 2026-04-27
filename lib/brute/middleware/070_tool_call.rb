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
        @app.call(env).tap do
          if env[:messages].last.tool_call?
            pending_tools = message.tool_calls.reject { |_id, tc| tc.name == "question" }

            if pending_tools.any?
              env[:events] << on_tool_call_start_event(pending_tools)

              pending_tools.each do |_id, tool_call|
                tool.call(tool_call.arguments)

                env[:events] << { type: :tool_result, data: { name: tc.name, content: content } }
                env[:messages] << RubyLLM::Message.new(role: :tool, content: content, tool_call_id: tc.id)
              end
            end
          end
        end
      end

      private

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
