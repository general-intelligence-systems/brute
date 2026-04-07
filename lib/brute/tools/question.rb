# frozen_string_literal: true

module Brute
  module Tools
    class Question < LLM::Tool
      name "question"
      description "Ask the user questions during execution. Use this to gather preferences, " \
                  "clarify ambiguous instructions, get decisions on implementation choices, or " \
                  "offer choices about direction. Users can always select \"Other\" to provide " \
                  "custom text input. Answers are returned as arrays of labels; set multiple: true " \
                  "to allow selecting more than one. If you recommend a specific option, make it " \
                  "the first option and add \"(Recommended)\" at the end of the label."

      params do |s|
        s.object(
          questions: s.array(
            s.object(
              question: s.string.required,
              header: s.string.required,
              options: s.array(
                s.object(
                  label: s.string.required,
                  description: s.string.required,
                )
              ).required,
              multiple: s.boolean,
            )
          ).required
        )
      end

      def call(questions:)
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
