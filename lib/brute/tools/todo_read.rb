# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Tools
    class TodoRead < LLM::Tool
      name "todo_read"
      description "Read the current todo list to check task status and progress."
      param :_placeholder, String, "Unused, pass any value"

      def call(_placeholder: nil)
        {todos: Brute::Store::TodoStore.all}
      end
    end
  end
end
