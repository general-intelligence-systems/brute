# frozen_string_literal: true

require "digest"
require "open3"
require "time"

module PrimeAgent
  # Autonomous — bounded continuations with quality gates. The port of
  # prime-agent's packages/coding-agent/src/core/autonomous.ts: when no human
  # input is expected, the host injects follow-up continuations until
  # configured gates pass or a continuation/turn/token/wall-clock limit is
  # reached. Prompts, defaults, the gate-failure message format, and the git
  # worktree snapshot (with its exclusions) are ported verbatim.
  #
  # Pure stdlib — loadable without brute or any gem.
  module Autonomous
    DEFAULT_CONTINUATION_PROMPT =
      "No human input is available in autonomous mode. Continue working until the host evaluator, verifier, or configured autonomous limits stop the run. If you were asking the user a question, make a reasonable assumption and verify it. If you believe you are blocked, prove it with host-observable evidence, preserve that evidence, and keep looking for safe progress while budget remains. Do not end the session yourself; the verifier/evaluator decides completion when configured gates pass."

    DEFAULT_LIMITS = {
      max_continuations: 3,
      max_turns: 12,
      max_tokens: 80_000,
      timeout_ms: 30 * 60 * 1000,
    }.freeze
    DEFAULT_GATE_MAX_RETRIES = 3
    DEFAULT_GATE_TIMEOUT_MS = 5 * 60 * 1000

    MAX_GATE_OUTPUT_CHARS = 6000
    MAX_CHILD_PROCESS_OUTPUT_CHARS = 1024 * 1024

    # Mutable runtime state (upstream mutates AutonomousRuntimeState:
    # gate attempts and last failure evolve across checks).
    State = Struct.new(
      :enabled, :continuations_used, :turns_used, :tokens_used, :started_at,
      :limits, :continuation_prompt, :gate_commands, :gate_max_retries,
      :gate_timeout_ms, :gate_attempts, :last_gate_failure, :last_gate_failure_snapshot,
      keyword_init: true,
    )

    module_function

    # createAutonomousRuntimeState (autonomous.ts:106-133).
    def build_state(enabled:, gates: [], continuation_prompt: nil,
                    max_continuations: nil, max_turns: nil, max_tokens: nil, timeout_ms: nil,
                    gate_max_retries: nil, gate_timeout_ms: nil, now: Time.now)
      State.new(
        enabled: enabled,
        continuations_used: 0,
        turns_used: 0,
        tokens_used: 0,
        started_at: enabled ? now : nil,
        limits: {
          max_continuations: normalize_limit(max_continuations, DEFAULT_LIMITS[:max_continuations]),
          max_turns: normalize_limit(max_turns, DEFAULT_LIMITS[:max_turns]),
          max_tokens: normalize_limit(max_tokens, DEFAULT_LIMITS[:max_tokens]),
          timeout_ms: normalize_limit(timeout_ms, DEFAULT_LIMITS[:timeout_ms]),
        },
        continuation_prompt: continuation_prompt.to_s.strip.empty? ? DEFAULT_CONTINUATION_PROMPT : continuation_prompt.strip,
        gate_commands: gates,
        gate_max_retries: normalize_limit(gate_max_retries, DEFAULT_GATE_MAX_RETRIES),
        gate_timeout_ms: normalize_limit(gate_timeout_ms, DEFAULT_GATE_TIMEOUT_MS),
        gate_attempts: {},
        last_gate_failure: nil,
        last_gate_failure_snapshot: nil,
      )
    end

    def normalize_limit(value, fallback)
      return fallback if value.nil? || !value.is_a?(Numeric) || value <= 0

      value.truncate
    end

    # autonomousLimitReason (autonomous.ts:254-271) — first exceeded wins.
    def limit_reason(state, now: Time.now)
      return "maxContinuations" if state.continuations_used >= state.limits[:max_continuations]
      return "maxTurns" if state.turns_used >= state.limits[:max_turns]
      return "maxTokens" if state.tokens_used >= state.limits[:max_tokens]
      if state.started_at && (now - state.started_at) * 1000 >= state.limits[:timeout_ms]
        return "timeoutMs"
      end

      nil
    end

    # shouldAutonomouslyContinue (autonomous.ts:227-252). Never continues
    # after an error/aborted turn; gates run before the limit check.
    def should_continue(state, error_turn:, cwd:, now: Time.now)
      return { continue: false, reason: "not_needed" } if !state.enabled || error_turn

      gate_result = state.gate_commands.empty? ? nil : run_gates(state, cwd)
      if gate_result
        return { continue: false, reason: "not_needed" } if gate_result == "passed"
        if gate_result == "retry_exhausted" || limit_reason(state, now: now)
          return { continue: false, reason: "limit_reached" }
        end

        return { continue: true, reason: "gate_failed" }
      end
      return { continue: false, reason: "limit_reached" } if limit_reason(state, now: now)

      { continue: true, reason: "missing_terminal_evidence" }
    end

    # runAutonomousQualityGates (autonomous.ts:284-348): each gate command
    # runs through the shell; exit 0 = pass. A failed gate is NOT rerun while
    # the worktree snapshot is unchanged — the attempt counter increments
    # with the synthetic "not rerun" failure instead.
    def run_gates(state, cwd)
      return "failed" if cwd.nil?

      state.gate_commands.each do |command|
        current_snapshot = capture_git_worktree_snapshot(cwd)
        if state.last_gate_failure && state.last_gate_failure["command"] == command &&
           state.last_gate_failure_snapshot &&
           snapshots_equal?(current_snapshot, state.last_gate_failure_snapshot)
          attempt = (state.gate_attempts[command] || state.last_gate_failure["attempt"]) + 1
          state.gate_attempts[command] = attempt
          state.last_gate_failure = state.last_gate_failure.merge(
            "attempt" => attempt,
            "exit_text" => "not rerun: workspace unchanged since previous failed gate",
            "output" => "The autonomous gate was not rerun because the workspace has not changed since this failure. Edit source files, tests, or a blocker artifact before attempting to finish again.",
          )
          return attempt > state.gate_max_retries ? "retry_exhausted" : "failed"
        end

        result = run_child_process(command, cwd: cwd, shell: true,
                                   timeout_ms: state.gate_timeout_ms,
                                   max_output_chars: MAX_GATE_OUTPUT_CHARS)
        post_run_snapshot = capture_git_worktree_snapshot(cwd)
        if result[:status] == 0 && result[:error].nil? && !result[:timed_out]
          state.gate_attempts[command] = 0
          if state.last_gate_failure && state.last_gate_failure["command"] == command
            state.last_gate_failure = nil
            state.last_gate_failure_snapshot = nil
          end
          next
        end

        attempt = (state.gate_attempts[command] || 0) + 1
        state.gate_attempts[command] = attempt
        state.last_gate_failure = {
          "command" => command,
          "attempt" => attempt,
          "exit_text" => format_process_exit(result),
          "output" => truncate_gate_output(
            [result[:stdout], result[:stderr]].compact.join("\n").strip,
            result[:output_truncated],
          ),
        }
        state.last_gate_failure_snapshot = post_run_snapshot
        return attempt > state.gate_max_retries ? "retry_exhausted" : "failed"
      end
      state.last_gate_failure = nil
      state.last_gate_failure_snapshot = nil
      "passed"
    end

    # buildAutonomousGateFailureContinuation (autonomous.ts:350-360), verbatim.
    def build_gate_failure_continuation(failure, max_retries, timestamp: Time.now)
      "Autonomous quality gate failed (attempt #{failure["attempt"]}/#{max_retries}): " \
      "`#{failure["command"]}` #{failure["exit_text"]}.\n" \
      "\nOutput:\n#{failure["output"]}\n" \
      "\nContinue working. Fix the failure, then produce terminal evidence. " \
      "Timestamp: #{timestamp.utc.iso8601}."
    end

    # ------------------------------------------------------------------
    # Git worktree snapshot (autonomous.ts:370-469)
    # ------------------------------------------------------------------

    GATE_PATHSPEC = [
      "--", ".",
      ":(exclude)verification",
      ":(exclude)target",
      ":(exclude).vf-prime-agent",
      ":(exclude)Cargo.lock",
      ":(exclude)submission.tar.gz",
      ":(exclude)runner_args.log",
    ].freeze

    def snapshots_equal?(a, b)
      !a.nil? && !b.nil? &&
        a["status"] == b["status"] && a["diff"] == b["diff"] &&
        a["untracked_hash"] == b["untracked_hash"]
    end

    def capture_git_worktree_snapshot(cwd)
      status = run_child_process(
        ["git", "--no-optional-locks", "status", "--porcelain=v1", "-z", "-uall", "--no-renames"] + GATE_PATHSPEC,
        cwd: cwd, timeout_ms: 10_000,
      )
      return nil unless snapshot_ok?(status)

      diff = run_child_process(
        ["git", "--no-optional-locks", "diff", "--no-ext-diff", "--binary", "HEAD"] + GATE_PATHSPEC,
        cwd: cwd, timeout_ms: 10_000,
      )
      return nil unless snapshot_ok?(diff)

      {
        "status" => status[:stdout],
        "diff" => diff[:stdout],
        "untracked_hash" => hash_untracked_files(cwd, status[:stdout]),
      }
    end

    def snapshot_ok?(result)
      result[:status] == 0 && result[:error].nil? && !result[:timed_out] && !result[:output_truncated]
    end

    def hash_untracked_files(cwd, status)
      aggregate = Digest::SHA256.new
      status.split("\0").select { |entry| entry.start_with?("?? ") }
            .map { |entry| entry[3..] }.sort.each do |path|
        aggregate.update(path)
        aggregate.update("\0")
        aggregate.update(hash_untracked_path(File.join(cwd, path)))
        aggregate.update("\0")
      end
      aggregate.hexdigest
    end

    def hash_untracked_path(path)
      stat = File.lstat(path)
      return "symlink:#{File.readlink(path)}" if stat.symlink?
      unless stat.file?
        return "other:#{stat.mode}:#{stat.size}:#{(stat.mtime.to_f * 1000).round}"
      end

      "file:#{Digest::SHA256.file(path).hexdigest}"
    rescue SystemCallError => error
      "error:#{error.message}"
    end

    # ------------------------------------------------------------------
    # Child processes (autonomous.ts:481-586)
    # ------------------------------------------------------------------

    # runChildProcess: captured stdout/stderr with per-stream caps, a wall
    # timeout that kills the process group, and timed_out/output_truncated
    # flags. shell: true runs the command through the shell (gate commands).
    def run_child_process(command, cwd:, shell: false, timeout_ms: nil,
                          max_output_chars: MAX_CHILD_PROCESS_OUTPUT_CHARS)
      result = {
        status: nil, signal: nil, stdout: +"", stderr: +"",
        error: nil, timed_out: false, output_truncated: false,
      }
      argv = shell ? command : Array(command)
      Open3.popen3(*argv, chdir: cwd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        readers = { stdout => result[:stdout], stderr => result[:stderr] }.map do |io, buffer|
          Thread.new do
            loop do
              chunk = io.readpartial(16_384)
              remaining = max_output_chars - buffer.length
              buffer << chunk[0, remaining] if remaining.positive?
              result[:output_truncated] ||= chunk.length > remaining
            rescue EOFError, IOError
              break
            end
          end
        end
        if timeout_ms && !wait_thr.join(timeout_ms / 1000.0)
          result[:timed_out] = true
          begin
            Process.kill("KILL", -wait_thr.pid) # the spawned process group
          rescue Errno::ESRCH
            nil
          end
        end
        status = wait_thr.value
        readers.each(&:join)
        result[:status] = status.exitstatus
        result[:signal] = status.termsig
      end
      result
    rescue SystemCallError => error
      result[:error] = error
      result
    end

    # formatProcessExit (autonomous.ts:571-579).
    def format_process_exit(result)
      return "timed out" if result[:timed_out]
      return result[:error].message if result[:error]

      result[:signal] ? "terminated by #{result[:signal]}" : "exited #{result[:status] || "unknown"}"
    end

    # truncateGateOutput (autonomous.ts:581-586).
    def truncate_gate_output(output, output_already_truncated = false, max_chars = MAX_GATE_OUTPUT_CHARS)
      return output if output.length <= max_chars && !output_already_truncated

      "#{output[0...max_chars]}\n... [truncated]"
    end
  end
end

__END__

require "tmpdir"

describe "prime_agent/autonomous" do
  A = PrimeAgent::Autonomous

  def state(**overrides)
    A.build_state(enabled: true, **overrides)
  end

  it "normalizes limits to upstream defaults" do
    s = A.build_state(enabled: true)
    s.limits.should == { max_continuations: 3, max_turns: 12, max_tokens: 80_000, timeout_ms: 1_800_000 }
    s.gate_max_retries.should == 3
    s.gate_timeout_ms.should == 300_000
    s.continuation_prompt.should == A::DEFAULT_CONTINUATION_PROMPT
    A.normalize_limit(nil, 5).should == 5
    A.normalize_limit(-2, 5).should == 5
    A.normalize_limit(7.9, 5).should == 7
  end

  it "reports the first exceeded limit in order" do
    s = state
    A.limit_reason(s).should.be.nil
    s.continuations_used = 3
    A.limit_reason(s).should == "maxContinuations"
    s.turns_used = 12
    s.continuations_used = 1
    A.limit_reason(s).should == "maxTurns"
    s.turns_used = 1
    s.tokens_used = 80_000
    A.limit_reason(s).should == "maxTokens"
    s.tokens_used = 1
    s.started_at = Time.now - 2000
    s.limits[:timeout_ms] = 1000
    A.limit_reason(s).should == "timeoutMs"
  end

  it "never continues after an error turn or when disabled" do
    A.should_continue(state, error_turn: true, cwd: Dir.pwd)[:reason].should == "not_needed"
    disabled = A.build_state(enabled: false)
    A.should_continue(disabled, error_turn: false, cwd: Dir.pwd)[:continue].should.be.false
  end

  it "continues with missing_terminal_evidence when there are no gates" do
    A.should_continue(state, error_turn: false, cwd: Dir.pwd)
     .should == { continue: true, reason: "missing_terminal_evidence" }
  end

  it "formats the gate-failure continuation verbatim" do
    text = A.build_gate_failure_continuation(
      { "command" => "npm run check", "attempt" => 2, "exit_text" => "exited 1", "output" => "boom" },
      3,
      timestamp: Time.utc(2026, 8, 16, 10, 0, 0),
    )
    text.should == "Autonomous quality gate failed (attempt 2/3): `npm run check` exited 1.\n" \
                   "\nOutput:\nboom\n" \
                   "\nContinue working. Fix the failure, then produce terminal evidence. " \
                   "Timestamp: 2026-08-16T10:00:00Z."
  end

  it "formats process exits and truncates gate output" do
    A.format_process_exit({ timed_out: true }).should == "timed out"
    A.format_process_exit({ signal: 9, status: nil }).should == "terminated by 9"
    A.format_process_exit({ signal: nil, status: 1 }).should == "exited 1"
    A.truncate_gate_output("short").should == "short"
    A.truncate_gate_output("x" * 7000).should.end_with "\n... [truncated]"
    A.truncate_gate_output("x" * 7000).length.should == 6000 + "\n... [truncated]".length
  end

  it "runs child processes with status, output caps, and timeout kills" do
    Dir.mktmpdir do |dir|
      ok = A.run_child_process("echo hello", cwd: dir, shell: true)
      ok[:status].should == 0
      ok[:stdout].should == "hello\n"

      fail = A.run_child_process("echo oops >&2; exit 3", cwd: dir, shell: true)
      fail[:status].should == 3
      fail[:stderr].should.include "oops"

      slow = A.run_child_process("sleep 30", cwd: dir, shell: true, timeout_ms: 100)
      slow[:timed_out].should.be.true
      A.format_process_exit(slow).should == "timed out"

      big = A.run_child_process("ruby -e 'puts \"x\" * 90000'", cwd: dir, shell: true, max_output_chars: 100)
      big[:output_truncated].should.be.true
      big[:stdout].length.should == 100
    end
  end

  it "snapshots the worktree and detects changes" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "tracked.txt"), "v1")
      setup_ok = system("git", "-C", dir, "init", "-q") &&
                 system("git", "-C", dir, "add", "-A") &&
                 system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")
      raise "git setup failed" unless setup_ok

      clean = A.capture_git_worktree_snapshot(dir)
      clean.should.not.be.nil
      A.snapshots_equal?(clean, clean).should.be.true

      File.write(File.join(dir, "untracked.txt"), "new")
      with_untracked = A.capture_git_worktree_snapshot(dir)
      A.snapshots_equal?(clean, with_untracked).should.be.false

      File.write(File.join(dir, "tracked.txt"), "v2")
      A.snapshots_equal?(with_untracked, A.capture_git_worktree_snapshot(dir)).should.be.false
    end
  end

  it "gate flow: fail, skip while unchanged, rerun on change, retry_exhausted, pass" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "README"), "init")
      setup_ok = system("git", "-C", dir, "init", "-q") &&
                 system("git", "-C", dir, "add", "-A") &&
                 system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")
      raise "git setup failed" unless setup_ok

      s = state(gates: ["false"]) # always fails

      A.run_gates(s, dir).should == "failed"
      s.last_gate_failure["attempt"].should == 1
      s.last_gate_failure["exit_text"].should == "exited 1"

      A.run_gates(s, dir).should == "failed" # unchanged -> not rerun
      s.last_gate_failure["attempt"].should == 2
      s.last_gate_failure["exit_text"].should.include "not rerun"

      File.write(File.join(dir, "change.txt"), "x") # workspace changes
      A.run_gates(s, dir).should == "failed"        # rerun happened
      s.last_gate_failure["attempt"].should == 3
      s.last_gate_failure["exit_text"].should == "exited 1"

      A.run_gates(s, dir).should == "retry_exhausted" # unchanged, attempt 4 > maxRetries

      s2 = state(gates: ["true"])
      A.run_gates(s2, dir).should == "passed"
    end
  end
end
