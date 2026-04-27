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
        @app.call(env).tap do
          if env[:messages].last.tool_call?
            questions = last_message.tool_calls.select { |_id, tc| tc.name == "question" }

            if questions.any?
              env[:events] << {
                type: :tool_call_start,
                data: questions.map { |_id, tc| { name: tc.name, call_id: tc.id, arguments: tc.arguments } }
              }

              questions.each do |_id, tc|
                result = tc.call

                if result.is_a?(String)
                  content = result
                else
                  content = result.to_s
                end

                env[:events] << { type: :tool_result, data: { name: tc.name, content: content } }

                env[:messages] << RubyLLM::Message.new(
                  role: :tool, content: content, tool_call_id: tc.id
                )
              end
            end
          end
        end
      end
    end
  end
end

test do
  # not implemented
end
