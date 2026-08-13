module Brute
  class MessageTransport
    class RubyOpenAI < MessageTransport

      # Brute::Message -> ruby-openai Hash payload
      def self.dump(message)
        payload = {
          role: message.role.to_s
        }

        # Include content if present
        payload[:content] = message.content if message.content

        # Include tool call ID for tool outputs
        payload[:tool_call_id] = message.tool_call_id if message.tool_call_id

        # Convert Brute::ToolCall objects to ruby-openai nested tool call hashes
        if message.tool_call?
          payload[:tool_calls] = message.tool_calls.map do |tc|
            {
              id: tc.id,
              type: "function",
              function: {
                name: tc.name,
                arguments: tc.arguments.is_a?(String) ? tc.arguments : tc.arguments.to_json
              }
            }
          end
        end

        payload
      end

      private

      # ruby-openai Hash (or API response choice message) -> Brute::Message
      def wrap(message)
        # Normalize keys to symbols for pattern matching
        hash = message.to_h.transform_keys(&:to_sym)

        case hash
        # Branch 1: System, User, or Tool responses with text content
        in { role: ("system" | "user" | "tool") => role }
          Brute::Message.new(
            role: role,
            content: hash[:content],
            tool_call_id: hash[:tool_call_id]
          )

        # Branch 2: Assistant tool calls request
        in { role: "assistant", tool_calls: Array => raw_calls }
          tool_calls = raw_calls.map do |tc|
            # Handle both string and symbol keys within nested tool_call hashes
            tc_hash = tc.to_h.transform_keys(&:to_sym)
            fn_hash = (tc_hash[:function] || {}).transform_keys(&:to_sym)

            Brute::ToolCall.new(
              id: tc_hash[:id],
              name: fn_hash[:name],
              arguments: fn_hash[:arguments]
            )
          end

          Brute::Message.new(
            role: :assistant,
            content: hash[:content],
            tool_calls: tool_calls
          )

        # Branch 3: Standard Assistant text message
        in { role: "assistant" }
          Brute::Message.new(
            role: :assistant,
            content: hash[:content]
          )

        else
          raise "Unrecognised message format for ruby-openai: #{message.inspect}"
        end
      end
    end
  end
end
