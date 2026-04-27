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

        last_message = env[:messages].last

        if last_message&.tool_call?
          tool_calls = last_message.tool_calls

          # Filter out question tools (already handled by Question middleware)
          remaining = tool_calls.reject { |_id, tc| tc.name == "question" }

          if remaining.any?
            tools = build_tools_hash(env[:tools])

            env[:events] << {
              type: :tool_call_start,
              data: remaining.map { |_id, tc| { name: tc.name, call_id: tc.id, arguments: tc.arguments } }
            }

            remaining.each do |_id, tc|
              tool = tools[tc.name]
              result = if tool
                         tool.call(tc.arguments)
                       else
                         { error: "Unknown tool: #{tc.name}. Available: #{tools.keys.join(', ')}" }
                       end

              content = result.is_a?(String) ? result : result.to_s
              env[:events] << { type: :tool_result, data: { name: tc.name, content: content } }

              env[:messages] << RubyLLM::Message.new(
                role: :tool, content: content, tool_call_id: tc.id
              )
            end
          end

          env
        else
          env
        end
      end

      private

        def build_tools_hash(tools)
          if tools&.any?
            tools.each_with_object({}) do |tool, hash|
              instance = tool.is_a?(Class) ? tool.new : tool
              hash[instance.name.to_s] = instance
            end
          else
            {}
          end
        end
    end
  end
end

test do
  # not implemented
end
