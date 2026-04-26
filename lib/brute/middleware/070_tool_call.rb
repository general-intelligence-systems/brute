# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Executes non-question tool calls in parallel.
    #
    # Runs POST-call. After the LLM response is appended to env[:messages],
    # this middleware checks if the last message has tool calls:
    #
    #   1. Reads tool calls from env[:messages].last.tool_calls
    #   2. Skips any already handled by Question middleware (question tools removed)
    #   3. Fires :on_tool_call_start for the batch
    #   4. Executes each tool call
    #   5. Fires :on_tool_result per tool
    #   6. Appends :tool role messages directly to env[:messages]
    #
    # No parallel state arrays. The conversation history IS the state.
    #
    class ToolCall
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)

        last_message = env[:messages].last
        return env unless last_message&.tool_call?

        tools_hash = build_tools_hash(env[:tools])
        tool_calls = last_message.tool_calls

        # Filter out question tools (already handled by Question middleware)
        remaining = tool_calls.reject { |_id, tc| tc.name == "question" }
        return env unless remaining.any?

        # Fire tool_call_start with the batch
        env[:events] << {
          type: :tool_call_start,
          data: remaining.map { |_id, tc| { name: tc.name, call_id: tc.id, arguments: tc.arguments } }
        }

        remaining.each do |_id, tc|
          callable = ToolCallable.new(tc, tools_hash)
          result = callable.call

          content = result.is_a?(String) ? result : result.to_s
          env[:events] << { type: :tool_result, data: { name: tc.name, content: content } }

          # Append tool result directly to conversation history
          env[:messages] << RubyLLM::Message.new(
            role: :tool, content: content, tool_call_id: tc.id
          )
        end

        env
      end

      private

        def build_tools_hash(tools)
          return {} unless tools&.any?

          tools.each_with_object({}) do |tool, hash|
            instance = tool.is_a?(Class) ? tool.new : tool
            hash[instance.name.to_s] = instance
          end
        end

        # Wraps a RubyLLM::ToolCall + tools hash into a callable.
        class ToolCallable
          attr_reader :id, :name, :arguments

          def initialize(tool_call, tools_hash)
            @id = tool_call.id
            @name = tool_call.name
            @arguments = tool_call.arguments
            @tools_hash = tools_hash
          end

          def call
            tool = @tools_hash[@name]
            unless tool
              return { error: "Unknown tool: #{@name}. Available: #{@tools_hash.keys.join(', ')}" }
            end
            tool.call(@arguments)
          end
        end
    end
  end
end

test do
  # not implemented
end
