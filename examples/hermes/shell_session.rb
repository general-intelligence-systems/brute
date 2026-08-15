# frozen_string_literal: true

require "securerandom"
require "shellwords"
require "tempfile"
require "timeout"
require "English"

module Hermes
  # A persistent local shell session — port of hermes-agent's
  # tools/environments/base.py (local backend) mechanics:
  #
  #   * Shell state persists across calls via a sourced snapshot: every call
  #     re-sources the snapshot (env/exports from prior commands), runs the
  #     command, then re-dumps `export -p` back to the snapshot.
  #   * CWD persists via an in-band marker printed at the end of each call;
  #     killed/timed-out commands never emit it, so cwd survives failures.
  #   * Timeout kills the whole process group (rc 124).
  class ShellSession
    DEFAULT_TIMEOUT = 180
    FOREGROUND_MAX_TIMEOUT = 600

    attr_reader :cwd

    def initialize(workdir: Dir.pwd, state_dir: Dir.pwd)
      @cwd = workdir
      @snapshot = File.join(state_dir, ".hermes_shell_snapshot.sh")
    end

    # Returns { output:, exit_code:, cwd: }.
    def exec(command, cwd: nil, timeout: DEFAULT_TIMEOUT)
      marker = "__HERMES_CWD_#{SecureRandom.hex(6)}__"
      target_cwd = cwd || @cwd

      inner = <<~BASH
        [ -f #{@snapshot.shellescape} ] && source #{@snapshot.shellescape}
        cd #{target_cwd.shellescape} || exit 1
        export AI_AGENT=hermes-agent
        eval #{command.shellescape}
        __ec=$?
        export -p > #{@snapshot.shellescape} 2>/dev/null
        printf '\\n#{marker}%s' "$PWD"
        exit $__ec
      BASH

      out = Tempfile.new("hermes-shell")
      io = File.open(out.path, "a")
      pid = Process.spawn("bash", "-c", inner, pgroup: true,
                          out: io, err: [:child, :out])
      io.close
      timed_out = false
      begin
        Timeout.timeout(timeout) { Process.wait(pid) }
      rescue Timeout::Error
        timed_out = true
        begin
          Process.kill("TERM", -Process.getpgid(pid))
          sleep 0.2
          Process.kill("KILL", -Process.getpgid(pid))
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
        Process.wait(pid)
      end

      raw = File.read(out.path, encoding: Encoding::UTF_8)
      out.close!
      exit_code = timed_out ? 124 : ($CHILD_STATUS&.exitstatus || 0)

      # Parse the trailing CWD marker; absent on kill/timeout (cwd survives).
      if raw =~ /\n?#{Regexp.escape(marker)}(.+)\z/
        @cwd = $1.strip
        raw = raw.sub(/\n?#{Regexp.escape(marker)}.+\z/m, "")
      end

      { output: raw, exit_code: exit_code, cwd: @cwd }
    end
  end
end
