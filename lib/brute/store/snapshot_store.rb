# frozen_string_literal: true

module Brute
  # @namespace
  module Store
    # Per-path stack of file snapshots used by fs_write, fs_patch, fs_remove
    # to enable undo. Each call to .save pushes the current content (or
    # :did_not_exist for new files). .pop retrieves the most recent snapshot.
    module SnapshotStore
      @snapshots = Hash.new { |h, k| h[k] = [] }
      @mutex     = Mutex.new

      class << self
        # Push the current content of +path+ onto the snapshot stack.
        # If the file doesn't exist yet, records +:did_not_exist+.
        def save(path)
          key = File.expand_path(path)
          content = File.exist?(key) ? File.read(key) : :did_not_exist
          @mutex.synchronize { @snapshots[key].push(content) }
        end

        # Pop and return the most recent snapshot for +path+, or +nil+
        # if there is no history.
        def pop(path)
          key = File.expand_path(path)
          @mutex.synchronize { @snapshots[key].pop }
        end

        # Clear all snapshots. Used in tests and session resets.
        def clear!
          @mutex.synchronize { @snapshots.clear }
        end
      end
    end
  end
end
