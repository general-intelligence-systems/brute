# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/tools"

module Brute
  module Tools
    class TodoRead < RubyLLM::Tool
      description "Read the current todo list to check task status and progress."
      param :_placeholder, type: 'string', desc: "Unused, pass any value", required: false

      def name; "todo_read"; end

      def execute(_placeholder: nil)
        {todos: Brute::Store::TodoStore.all}
      end
    end
  end
end
