# frozen_string_literal: true

require "json"

module Hermes
  # Per-session todo store — full port of hermes-agent tools/todo_tool.py's
  # TodoStore. Items: {id, content, status}. List order IS priority order.
  class TodoStore
    VALID_STATUSES = %w[pending in_progress completed cancelled].freeze
    MAX_TODO_CONTENT_CHARS = 4_000
    MAX_TODO_ITEMS = 256
    MAX_TODO_RESULT_CHARS = 512_000

    # After context compression, active items are re-injected as a synthetic
    # message under this header (verbatim — compression recognizers key on it).
    INJECTION_HEADER = "[Your active task list was preserved across context compression]"
    MARKERS = { "completed" => "[x]", "in_progress" => "[>]", "pending" => "[ ]", "cancelled" => "[~]" }.freeze

    def initialize
      @items = []
    end

    def has_items? = !@items.empty?
    def items = @items.dup

    # Replace (merge: false) or merge-by-id (merge: true — updates only the
    # provided fields). Dedup by id, last wins. Returns the full list.
    def write(todos, merge: false)
      incoming = Array(todos).map { |t| normalize(t) }.compact
      incoming = incoming.select { |i| i[:content] } unless merge # replace-mode items need content
      return @items if incoming.empty? && !merge

      @items =
        if merge
          merged = @items.dup
          incoming.each do |new_item|
            idx = merged.index { |i| i[:id] == new_item[:id] }
            if idx
              merged[idx] = merged[idx].merge(new_item.compact)
            else
              merged << new_item
            end
          end
          merged
        else
          incoming.reverse.uniq { |i| i[:id] }.reverse # dedup by id, last wins
        end

      @items = @items.last(MAX_TODO_ITEMS)
      @items
    end

    def summary
      {
        total: @items.size,
        pending: @items.count { |i| i[:status] == "pending" },
        in_progress: @items.count { |i| i[:status] == "in_progress" },
        completed: @items.count { |i| i[:status] == "completed" },
        cancelled: @items.count { |i| i[:status] == "cancelled" },
      }
    end

    # Active items (pending/in_progress) for post-compaction re-injection.
    def format_for_injection
      active = @items.select { |i| %w[pending in_progress].include?(i[:status]) }
      return nil if active.empty?

      lines = active.map { |i| "#{MARKERS[i[:status]]} #{i[:content]}" }
      "#{INJECTION_HEADER}\n#{lines.join("\n")}"
    end

    # Rebuild state from prior todo tool results (resume hydration): the
    # latest write's full list wins.
    def hydrate(tool_results)
      latest = tool_results.filter_map do |content|
        data = begin
          JSON.parse(content.to_s)
        rescue JSON::ParserError
          nil
        end
        data["todos"] if data.is_a?(Hash) && data["todos"].is_a?(Array)
      end.last
      write(latest) if latest
    end

    private

    def normalize(todo)
      todo = todo.transform_keys(&:to_sym)
      return nil if todo[:id].to_s.empty?

      status = VALID_STATUSES.include?(todo[:status].to_s) ? todo[:status].to_s : "pending"
      item = { id: todo[:id].to_s, status: status }
      content = todo[:content].to_s
      item[:content] = content[0, MAX_TODO_CONTENT_CHARS] unless content.empty?
      item
    end
  end
end
