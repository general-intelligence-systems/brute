# frozen_string_literal: true

require "bundler/setup"
require "brute"
require "brute/tools"
require "brute/truncation"

require "open3"

module Brute
  module Tools
    # Existing features (ref: opencode bash tool):
    #
    # 1. Tail-mode truncation — when output exceeds limits, keep the LAST
    #    N lines / bytes instead of the first. Command output typically has
    #    the important info (errors, summaries) at the end.
    # 2. Save full output to disk — when truncating, write the complete
    #    output to a temp file and include the path in the truncated result
    #    so the LLM can use Read with offset/limit to inspect it.
    # 3. Align limits with universal truncation (2000 lines / 50 KB).
    # 4. Configurable per-call timeout — accept a timeout parameter from
    #    the LLM (defaults to 5 minutes).
    # 5. Return a plain string instead of a Hash.
    #
    class Shell < RubyLLM::Tool
      description "Execute a shell command and return stdout, stderr, and exit code. " \
                  "Use for git operations, running tests, installing packages, etc."

      param :command, type: 'string', desc: "The shell command to execute", required: true
      param :cwd, type: 'string', desc: "Working directory for the command (defaults to project root)", required: false
      param :timeout, type: 'integer', desc: "Timeout in seconds (defaults to 300)", required: false

      def name; "shell"; end

      DEFAULT_TIMEOUT = 300 # 5 minutes

      def execute(command:, cwd: nil, timeout: nil)
        dir = cwd ? File.expand_path(cwd) : Dir.pwd
        raise "Directory not found: #{dir}" unless File.directory?(dir)

        timeout_secs = timeout || DEFAULT_TIMEOUT
        stdout, stderr, status = nil
        Timeout.timeout(timeout_secs) do
          stdout, stderr, status = Open3.capture3("bash", "-c", command, chdir: dir)
        end

        out = stdout.to_s
        err = stderr.to_s

        # Combine output, preferring tail-mode truncation so errors/summaries at end are preserved
        combined = out
        combined += "\nSTDERR:\n#{err}" unless err.empty?
        combined += "\n[exit code: #{status.exitstatus}]" if status.exitstatus != 0

        Brute::Truncation.truncate(combined, direction: :tail)
      rescue Timeout::Error
        "Command timed out after #{timeout_secs}s: #{command}"
      end
    end
  end
end

test do
  #it "runs a command without error" do
  #  result = Brute::Tools::Shell.new.call(command: "echo hello")
  #  result.strip.should =~ /hello/
  #end

  #it "returns exit code" do
  #  result = Brute::Tools::Shell.new.call(command: "false")
  #  result.should =~ /exit code: 1/
  #end

  #it "returns a String, not a Hash" do
  #  Brute::Tools::Shell.new.call(command: "echo hello").should.be.kind_of(String)
  #end

  #it "preserves the end of output when truncating (tail mode)" do
  #  result = Brute::Tools::Shell.new.call(command: "seq 1 100000")
  #  result.should =~ /100000/
  #end

  ## --- Save full output to disk ---

  #it "saves full output to disk when truncated" do
  #  result = Brute::Tools::Shell.new.call(command: "seq 1 100000")
  #  result.should =~ /Full output saved to:/
  #end

  ## --- Configurable timeout ---

  #it "accepts a timeout parameter" do
  #  result = Brute::Tools::Shell.new.call(command: "sleep 0.1 && echo done", timeout: 10)
  #  result.should =~ /done/
  #end

  #it "times out with a short timeout" do
  #  result = Brute::Tools::Shell.new.call(command: "sleep 10", timeout: 1)
  #  result.should =~ /timed out/i
  #end
end
