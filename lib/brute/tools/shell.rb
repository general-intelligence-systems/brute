# frozen_string_literal: true

if __FILE__ == $0
  require "bundler/setup"
  require "brute"
end

require "open3"

module Brute
  module Tools
    class Shell < RubyLLM::Tool
      description "Execute a shell command and return stdout, stderr, and exit code. " \
                  "Use for git operations, running tests, installing packages, etc."

      param :command, type: 'string', desc: "The shell command to execute", required: true
      param :cwd, type: 'string', desc: "Working directory for the command (defaults to project root)", required: false

      def name; "shell"; end

      TIMEOUT = 300 # 5 minutes
      MAX_OUTPUT = 50_000

      def execute(command:, cwd: nil)
        dir = cwd ? File.expand_path(cwd) : Dir.pwd
        raise "Directory not found: #{dir}" unless File.directory?(dir)

        stdout, stderr, status = nil
        Timeout.timeout(TIMEOUT) do
          stdout, stderr, status = Open3.capture3("bash", "-c", command, chdir: dir)
        end

        out = stdout.to_s
        err = stderr.to_s
        out = out[0...MAX_OUTPUT] + "\n...(truncated)" if out.size > MAX_OUTPUT
        err = err[0...MAX_OUTPUT] + "\n...(truncated)" if err.size > MAX_OUTPUT

        {stdout: out, stderr: err, exit_code: status.exitstatus}
      rescue Timeout::Error
        {error: "Command timed out after #{TIMEOUT}s", command: command}
      end
    end
  end
end
