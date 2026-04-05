# frozen_string_literal: true

module Brute
  module Tools
    class FSRead < LLM::Tool
      name "read"
      description "Read the contents of a file. Returns file content with line numbers. " \
                  "Use start_line/end_line for partial reads of large files."

      param :file_path, String, "Absolute or relative path to the file to read", required: true
      param :start_line, Integer, "Starting line number (1-indexed). Omit to read from beginning"
      param :end_line, Integer, "Ending line number (inclusive). Omit to read to end"

      def call(file_path:, start_line: nil, end_line: nil)
        path = File.expand_path(file_path)
        raise "File not found: #{path}" unless File.exist?(path)
        raise "Not a file: #{path}" unless File.file?(path)

        lines = File.readlines(path)
        first = start_line ? [start_line - 1, 0].max : 0
        last = end_line ? [end_line - 1, lines.size - 1].min : lines.size - 1

        selected = lines[first..last] || []
        numbered = selected.each_with_index.map do |line, i|
          "#{first + i + 1}\t#{line}"
        end

        {
          file_path: path,
          total_lines: lines.size,
          showing: "#{first + 1}-#{last + 1}",
          content: numbered.join,
        }
      end
    end
  end
end
