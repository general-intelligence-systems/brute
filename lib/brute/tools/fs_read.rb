# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

module Brute
  module Tools
    class FSRead < RubyLLM::Tool
      description "Read the contents of a file. Returns file content with line numbers. " \
                  "Use start_line/end_line for partial reads of large files."

      param :file_path, type: 'string', desc: "Absolute or relative path to the file to read", required: true
      param :start_line, type: 'integer', desc: "Starting line number (1-indexed). Omit to read from beginning", required: false
      param :end_line, type: 'integer', desc: "Ending line number (inclusive). Omit to read to end", required: false

      def name; "read"; end

      def execute(file_path:, start_line: nil, end_line: nil)
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
