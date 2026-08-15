# frozen_string_literal: true

# Edit — port of prime-agent `packages/coding-agent/skills/edit/src/edit/__init__.py`:
# exact single-occurrence string replacement in an existing file.
# Loaded into IRuby via require "edit" (this skill's lib/ dir is on the kernel
# load path). Errors raise — the iruby tool renders them as the cell result,
# which is how the model sees "0 matches" / ">1 matches" (same as upstream).
module Edit
  module_function

  # Per-file mutation serialization — the port of prime-agent's
  # withFileMutationQueue (core/tools/file-mutation-queue.ts): operations on
  # the SAME file run one at a time, operations on DIFFERENT files run in
  # parallel. Symlink-aware (realpath, with an expand_path fallback for
  # not-yet-existing files); the per-file mutex is dropped when no one holds
  # or waits on it. KernelAgents run on threads inside this kernel, so a
  # child's read-modify-write can otherwise race a sibling's.
  module MutationQueue
    @mutexes = {}
    @waiters = Hash.new(0)
    @guard = Mutex.new

    class << self
      def serialize(path)
        key = canonical(path)
        mutex = @guard.synchronize do
          @mutexes[key] ||= Mutex.new
          @waiters[key] += 1
          @mutexes[key]
        end

        begin
          mutex.synchronize { yield }
        ensure
          @guard.synchronize do
            @waiters[key] -= 1
            if @waiters[key] <= 0
              @mutexes.delete(key)
              @waiters.delete(key)
            end
          end
        end
      end

      # Number of file paths currently tracked (diagnostics/specs).
      def size
        @guard.synchronize { @mutexes.size }
      end

      private

      def canonical(path)
        resolved = File.expand_path(path)
        File.realpath(resolved)
      rescue SystemCallError
        resolved
      end
    end
  end

  # Replace a unique string in a file. `old_str` must occur exactly once.
  # Returns a short confirmation; raises if `path` is missing or `old_str`
  # is absent or matches more than once (widen the snippet to make it unique).
  def run(path:, old_str:, new_str:)
    resolved, start_line = MutationQueue.serialize(path) do
      filepath = File.expand_path(path)
      raise Errno::ENOENT, "#{path} not found" unless File.exist?(filepath)

      content = File.read(filepath, encoding: Encoding::UTF_8)
      # NOTE: String#scan with a String pattern matches literally (no regexp),
      # non-overlapping — Ruby's equivalent of Python's str.count/substr.
      count = content.scan(old_str).size
      raise ArgumentError, "string not found in #{path}" if count.zero?
      if count > 1
        raise ArgumentError,
              "found #{count} occurrences in #{path}, need exactly 1 — " \
              "widen the snippet to make it unique"
      end

      match_index = content.index(old_str)
      line = content[0...match_index].count("\n") + 1

      # String#sub replaces the FIRST occurrence only (there is exactly one).
      File.write(filepath, content.sub(old_str, new_str))
      [File.realpath(filepath), line]
    end
    emit_diff(resolved, old_str, new_str, start_line)
    "Edited #{resolved}"
  end

  # Keep in sync with DIFF_DISPLAY_MIME in lib/prime_agent/kernel_manager.rb
  # (mirrors prime-agent's "Keep in sync with ... kernel/index.ts" comment).
  DIFF_DISPLAY_MIME = "application/vnd.prime-agent.diff+json"

  # Stream the diff to the host as a display_data side channel, exactly like
  # upstream's _emit_diff (the host KernelManager captures it onto the cell
  # result's `diffs`). Best-effort outside IRuby — a display failure must
  # never break the cell (upstream: bare `except`).
  def emit_diff(path, old_str, new_str, start_line)
    return unless defined?(IRuby::Kernel)

    IRuby::Kernel.instance.session.send(
      :publish, :display_data,
      data: {
        DIFF_DISPLAY_MIME => {
          "path" => path, "old_str" => old_str, "new_str" => new_str, "start_line" => start_line,
        },
        "text/plain" => "Edited #{path}",
      },
      metadata: {},
    )
    nil
  rescue StandardError
    nil
  end
end
