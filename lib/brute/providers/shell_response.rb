# frozen_string_literal: true

require "securerandom"

module Brute
  module Providers
    # Synthetic completion response returned by Brute::Providers::Shell.
    #
    # When +command+ is present, the response contains a single assistant
    # message with a "shell" tool call. The orchestrator picks it up and
    # executes Brute::Tools::Shell through the normal pipeline.
    #
    # When +command+ is nil (tool results round-trip), the response
    # contains an empty assistant message with no tool calls, causing
    # the orchestrator loop to exit.
    #
    class ShellResponse
      def initialize(command: nil, model: "bash", tools: [])
        @command    = command
        @model_name = model
        @tools      = tools || []
      end

      def messages
        return [empty_assistant] if @command.nil?

        call_id    = "shell_#{SecureRandom.hex(8)}"
        tool_call  = LLM::Object.from(
          id: call_id,
          name: "shell",
          arguments: { "command" => @command },
        )
        original = [{
          "type"  => "tool_use",
          "id"    => call_id,
          "name"  => "shell",
          "input" => { "command" => @command },
        }]

        [LLM::Message.new(:assistant, "", {
          tool_calls: [tool_call],
          original_tool_calls: original,
          tools: @tools,
        })]
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
        messages.find(&:assistant?)&.content
      end

      def content!
        LLM.json.load(content)
      end

      def reasoning_content
        nil
      end

      def usage
        LLM::Usage.new(
          input_tokens: 0,
          output_tokens: 0,
          reasoning_tokens: 0,
          total_tokens: 0,
        )
      end

      # Contract must be included AFTER method definitions —
      # LLM::Contract checks that all required methods exist at include time.
      include LLM::Contract::Completion

      private

      def empty_assistant
        LLM::Message.new(:assistant, "")
      end
    end
  end
end
