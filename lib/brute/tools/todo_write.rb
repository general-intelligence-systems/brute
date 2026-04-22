# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Tools
    class TodoWrite < LLM::Tool
      name "todo_write"
      description "Create or update the todo list. Send the complete list each time — " \
                  "this replaces the existing list entirely."

      params do |s|
        s.object(
          todos: s.array(
            s.object(
              id: s.string.required,
              content: s.string.required,
              status: s.string.enum("pending", "in_progress", "completed", "cancelled").required
            )
          ).required
        )
      end

      def call(todos:)
        items = todos.map do |t|
          t = t.transform_keys(&:to_sym) if t.is_a?(Hash)
          {id: t[:id], content: t[:content], status: t[:status]}
        end
        Brute::Store::TodoStore.replace(items)
        {success: true, count: items.size}
      end
    end
  end
end
