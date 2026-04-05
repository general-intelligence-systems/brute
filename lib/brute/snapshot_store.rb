# frozen_string_literal: true

module Brute
  # Copy-on-write snapshot storage for file undo support.
  # Saves the previous content of a file before mutation so it can be restored.
  # Each file maintains a stack of snapshots, supporting multiple undo levels.
  module SnapshotStore
    @store = {}
    @mutex = Mutex.new

    class << self
      # Save the current state of a file before mutating it.
      # If the file doesn't exist, records :did_not_exist so undo can delete it.
      def save(path)
        path = File.expand_path(path)
        @mutex.synchronize do
          @store[path] ||= []
          if File.exist?(path)
            @store[path].push(File.read(path))
          else
            @store[path].push(:did_not_exist)
          end
        end
      end

      # Pop the most recent snapshot for a file.
      # Returns the content string, :did_not_exist, or nil if no history.
      def pop(path)
        path = File.expand_path(path)
        @mutex.synchronize do
          @store[path]&.pop
        end
      end

      # Check how many undo levels are available for a file.
      def depth(path)
        path = File.expand_path(path)
        @mutex.synchronize do
          @store[path]&.size || 0
        end
      end

      # Clear all snapshots (useful for testing or session reset).
      def clear!
        @mutex.synchronize { @store.clear }
      end
    end
  end
end
