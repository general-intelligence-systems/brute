# frozen_string_literal: true

module Brute
  module Tools
    class TodoRead < LLM::Tool
      name "todo_read"
      description "Read the current todo list to check task status and progress."
      param :_placeholder, String, "Unused, pass any value"

      def call
        {todos: Brute::TodoStore.all}
      end
    end
  end
end
