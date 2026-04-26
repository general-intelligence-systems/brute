# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

require "securerandom"

module Brute
  module Providers
    # Synthetic completion response returned by Brute::Providers::Shell.
    #
    # When +command+ is present, the response contains a single assistant
    # message with a "shell" tool call. The agent loop picks it up and
    # executes Brute::Tools::Shell through the normal pipeline.
    #
    # When +command+ is nil (tool results round-trip), the response
    # contains an empty assistant message with no tool calls, causing
    # the agent loop to exit.
    #
    class ShellResponse
      def initialize(command: nil, model: "bash", tools: [])
        @command    = command
        @model_name = model
        @tools      = tools || []
      end

      def messages
        return [empty_assistant] if @command.nil?

        call_id = "shell_#{SecureRandom.hex(8)}"
        tool_calls = {
          call_id => RubyLLM::ToolCall.new(
            id: call_id,
            name: "shell",
            arguments: { "command" => @command },
          )
        }

        [RubyLLM::Message.new(
          role: :assistant,
          content: "",
          tool_calls: tool_calls,
        )]
      end
      alias_method :choices, :messages

      def model
        @model_name
      end

      def input_tokens
        0
      end

      def output_tokens
        0
      end

      def reasoning_tokens
        0
      end

      def total_tokens
        0
      end

      def content
        msg = messages.find { |m| m.role == :assistant }
        msg&.content
      end

      def content!
        JSON.parse(content)
      end

      def reasoning_content
        nil
      end

      def usage
        RubyLLM::Tokens.new(
          input: 0,
          output: 0,
          reasoning: 0,
        )
      end

      private

      def empty_assistant
        RubyLLM::Message.new(role: :assistant, content: "")
      end
    end
  end
end
