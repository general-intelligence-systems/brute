# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/tools"

module Brute
  module Tools
    class TodoWrite < Brute::Tool
      description "Create or update the todo list. Send the complete list each time — " \
                  "this replaces the existing list entirely."

      params(
        {
          type:       'object',
          properties: {
            todos: {
              type:  'array',
              items: {
                type:       'object',
                properties: {
                  id:      { type: 'string' },
                  content: { type: 'string' },
                  status:  { type: 'string', enum: %w[pending in_progress completed cancelled] },
                },
                required:   %w[id content status],
              },
            },
          },
          required:   %w[todos],
        },
      )

      def name; "todo_write"; end

      def execute(todos:)
        items = todos.map do |t|
          if t.is_a?(Hash)
            t = t.transform_keys(&:to_sym)
          end
          {id: t[:id], content: t[:content], status: t[:status]}
        end
        Brute::Tools::TodoList::Store.replace(items)
        {success: true, count: items.size}
      end
    end
  end
end
