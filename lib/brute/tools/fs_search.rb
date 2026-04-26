# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/tools"
require "open3"

module Brute
  module Tools
    class FSSearch < RubyLLM::Tool
      description "Search file contents using ripgrep (regex), or find files by glob pattern. " \
                  "Returns matching lines with file paths and line numbers."

      param :pattern, type: 'string', desc: "Regex pattern to search for in file contents", required: true
      param :path, type: 'string', desc: "Directory to search in (defaults to current working directory)", required: false
      param :glob, type: 'string', desc: "File glob filter, e.g. '*.rb', '*.{js,ts}'", required: false
      param :ignore_case, type: 'boolean', desc: "Case-insensitive search (default: false)", required: false

      def name; "fs_search"; end

      MAX_OUTPUT = 40_000

      def execute(pattern:, path: nil, glob: nil, ignore_case: false)
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
