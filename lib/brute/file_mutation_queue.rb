# frozen_string_literal: true

module Brute
  # Per-file serialization queue for concurrent tool execution.
  #
  # When tools run in parallel (via threads or async fibers), multiple tools
  # may target the same file simultaneously. Without serialization, a sequence
  # like [read → patch → write] on the same file would race and lose edits.
  #
  # This module provides a single public method:
  #
  #   Brute::FileMutationQueue.serialize("/path/to/file") do
  #     # snapshot + read + modify + write — all atomic for this path
  #   end
  #
  # Design (mirrors pi-mono's withFileMutationQueue):
  #   - Operations on the SAME file are serialized (run one at a time)
  #   - Operations on DIFFERENT files run fully in parallel (independent mutexes)
  #   - Symlink-aware: resolves real paths so aliases share one mutex
  #   - Error-safe: mutex is always released in `ensure`, so failures never deadlock
  #   - Self-cleaning: per-file mutexes are removed when no longer in use
  #
  # Ruby 3.4's Mutex is fiber-scheduler-aware, so this works correctly with
  # both :thread and :task (Async) concurrency strategies.
  #
  module FileMutationQueue
    @mutexes = {}       # path → Mutex
    @waiters = Hash.new(0) # path → number of threads/fibers waiting or holding
    @guard = Mutex.new  # protects @mutexes and @waiters

    class << self
      # Serialize a block of work for a given file path.
      #
      # Concurrent calls targeting the same canonical path will execute
      # sequentially in FIFO order. Calls targeting different paths
      # proceed in parallel with zero contention.
      #
      # @param path [String] The file path to serialize on.
      # @yield The mutation work to perform (snapshot, read, write, etc.)
      # @return Whatever the block returns.
      def serialize(path, &block)
        key = canonical_path(path)
        mutex = acquire_mutex(key)

        mutex.synchronize(&block)
      ensure
        release_mutex(key)
      end

      # Clear all tracked mutexes. Used in tests and session resets.
      def clear!
        @guard.synchronize do
          @mutexes.clear
          @waiters.clear
        end
      end

      # Number of file paths currently tracked (for diagnostics).
      def size
        @guard.synchronize { @mutexes.size }
      end

      private

      # Resolve a file path to a canonical key.
      # Uses File.realpath to follow symlinks so that aliases to the
      # same underlying file share one mutex. Falls back to
      # File.expand_path for files that don't exist yet (e.g., new writes).
      def canonical_path(path)
        resolved = File.expand_path(path)
        begin
          File.realpath(resolved)
        rescue Errno::ENOENT
          resolved
        end
      end

      # Get (or create) a mutex for a file path and increment the waiter count.
      def acquire_mutex(key)
        @guard.synchronize do
          @mutexes[key] ||= Mutex.new
          @waiters[key] += 1
          @mutexes[key]
        end
      end

      # Decrement the waiter count and clean up the mutex if no one else needs it.
      def release_mutex(key)
        @guard.synchronize do
          @waiters[key] -= 1
          if @waiters[key] <= 0
            @mutexes.delete(key)
            @waiters.delete(key)
          end
        end
      end
    end
  end
end
