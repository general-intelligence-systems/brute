# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Tools
    class Question < RubyLLM::Tool
      description "Ask the user questions during execution. Use this to gather preferences, " \
                  "clarify ambiguous instructions, get decisions on implementation choices, or " \
                  "offer choices about direction. Users can always select \"Other\" to provide " \
                  "custom text input. Answers are returned as arrays of labels; set multiple: true " \
                  "to allow selecting more than one. If you recommend a specific option, make it " \
                  "the first option and add \"(Recommended)\" at the end of the label."

      params({
        type: 'object',
        properties: {
          questions: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                question: { type: 'string' },
                header: { type: 'string' },
                options: {
                  type: 'array',
                  items: {
                    type: 'object',
                    properties: {
                      label: { type: 'string' },
                      description: { type: 'string' },
                    },
                    required: %w[label description],
                  },
                },
                multiple: { type: 'boolean' },
              },
              required: %w[question header options],
            },
          },
        },
        required: %w[questions],
      })

      def name; "question"; end

      def execute(questions:)
        handler = Thread.current[:on_question]
        unless handler
          return { error: true, message: "Cannot ask questions in non-interactive mode" }
        end

        queue = Queue.new
        handler.call(questions, queue)
        answers = queue.pop

        format_answers(questions, answers)
      end

      private

      def format_answers(questions, answers)
        pairs = questions.each_with_index.map do |q, i|
          q = q.transform_keys(&:to_s) if q.is_a?(Hash)
          header = q["header"]
          answer = answers[i] || []
          "\"#{header}\" = #{answer.join(', ')}"
        end

        { response: "User answered: #{pairs.join('; ')}" }
      end
    end
  end
end
