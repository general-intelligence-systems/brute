# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/tools"

module Brute
  module Tools
    class TodoWrite < RubyLLM::Tool
      description "Create or update the todo list. Send the complete list each time — " \
                  "this replaces the existing list entirely."

      params({
        type: 'object',
        properties: {
          todos: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                id: { type: 'string' },
                content: { type: 'string' },
                status: { type: 'string', enum: %w[pending in_progress completed cancelled] },
              },
              required: %w[id content status],
            },
          },
        },
        required: %w[todos],
      })

      def name; "todo_write"; end

      def execute(todos:)
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
