# frozen_string_literal: true

require "open3"

module Brute
  module Tools
    class FSSearch < LLM::Tool
      name "fs_search"
      description "Search file contents using ripgrep (regex), or find files by glob pattern. " \
                  "Returns matching lines with file paths and line numbers."

      param :pattern, String, "Regex pattern to search for in file contents", required: true
      param :path, String, "Directory to search in (defaults to current working directory)"
      param :glob, String, "File glob filter, e.g. '*.rb', '*.{js,ts}'"
      param :ignore_case, Boolean, "Case-insensitive search (default: false)"

      MAX_OUTPUT = 40_000

      def call(pattern:, path: nil, glob: nil, ignore_case: false)
        dir = File.expand_path(path || Dir.pwd)
        raise "Directory not found: #{dir}" unless File.directory?(dir)

        cmd = ["rg", "--line-number", "--max-count=100", "--max-columns=200"]
        cmd << "--ignore-case" if ignore_case
        cmd += ["--glob", glob] if glob
        cmd << pattern
        cmd << dir

        stdout, stderr, status = Open3.capture3(*cmd)

        output = stdout.empty? ? stderr : stdout
        output = output[0...MAX_OUTPUT] + "\n...(truncated)" if output.size > MAX_OUTPUT

        {results: output, exit_code: status.exitstatus, truncated: output.size > MAX_OUTPUT}
      end
    end
  end
end
