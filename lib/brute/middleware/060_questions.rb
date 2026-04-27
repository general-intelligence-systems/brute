# frozen_string_literal: true

require "bundler/setup"
require "brute"

module Brute
  module Middleware
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
