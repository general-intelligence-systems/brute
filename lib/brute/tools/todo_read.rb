# frozen_string_literal: true

module Brute
  module Tools
    class TodoRead < LLM::Tool
      name "todo_read"
      description "Read the current todo list to check task status and progress."

      def call
        {todos: Brute::TodoStore.all}
      end
    end
  end
end
