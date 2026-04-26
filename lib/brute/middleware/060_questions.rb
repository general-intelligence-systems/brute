# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
    # Executes question tool calls sequentially, with the on_question handler
    # available via Thread.current[:on_question].
    #
    # Runs POST-call. After the LLM response is appended to env[:messages],
    # this middleware checks for question tool calls:
    #
    #   1. Reads tool calls from env[:messages].last.tool_calls
    #   2. Partitions out tools where name == "question"
    #   3. Fires :on_tool_call_start for the question batch
    #   4. Executes each question sequentially (blocking, interactive)
    #   5. Fires :on_tool_result per question
    #   6. Appends :tool role messages directly to env[:messages]
    #
    # Questions run before parallel tools (in ToolCall) because they are
    # interactive and may block waiting for user input.
    #
    class Question
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)

        last_message = env[:messages].last
        return env unless last_message&.tool_call?

        questions = last_message.tool_calls.select { |_id, tc| tc.name == "question" }
        return env unless questions.any?

        # Fire tool_call_start with the question batch
        env[:events] << {
          type: :tool_call_start,
          data: questions.map { |_id, tc| { name: tc.name, call_id: tc.id, arguments: tc.arguments } }
        }

        questions.each do |_id, tc|
          result = tc.call
          content = result.is_a?(String) ? result : result.to_s

          env[:events] << { type: :tool_result, data: { name: tc.name, content: content } }

          env[:messages] << RubyLLM::Message.new(
            role: :tool, content: content, tool_call_id: tc.id
          )
        end

        env
      end
    end
  end
end

test do
  # not implemented
end
