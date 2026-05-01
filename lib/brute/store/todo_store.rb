# frozen_string_literal: true

module Brute
  # @namespace
  module Store
  # In-memory todo list storage. The agent uses this to track multi-step tasks.
  # The list is replaced wholesale on each todo_write call.
  module TodoStore
    @items = []
    @mutex = Mutex.new

    class << self
      # Replace the entire todo list.
      def replace(items)
        @mutex.synchronize { @items = items.dup }
      end

      # Return all current items.
      def all
        @mutex.synchronize { @items.dup }
      end

      # Clear all items.
      def clear!
        @mutex.synchronize { @items.clear }
      end
    end
  end
  end
end
