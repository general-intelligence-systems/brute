# frozen_string_literal: true

require "securerandom"
require "shellwords"
require "fileutils"

module Hermes
  # Background process registry — port of hermes-agent tools/process_registry.py
  # (local spawn path). Processes are spawned detached with output teed to a
  # log file and stdin backed by a FIFO, tracked by session id.
  class ProcessRegistry
    ProcessEntry = Struct.new(:session_id, :pid, :command, :log_path, :stdin_path, :started_at, keyword_init: true) do
      def alive?
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def exit_status
        return nil if alive?

        begin
          _pid, status = Process.wait2(pid, Process::WNOHANG)
          status&.exitstatus
        rescue Errno::ECHILD
          nil
        end
      end
    end

    def initialize(log_dir: File.join(Dir.pwd, "processes"))
      @log_dir = log_dir
      @entries = {}
      FileUtils.mkdir_p(@log_dir)
    end

    def spawn(command, workdir: nil, notify: false)
      session_id = "proc-#{SecureRandom.hex(4)}"
      log_path = File.join(@log_dir, "#{session_id}.log")
      stdin_path = File.join(@log_dir, "#{session_id}.stdin")
      system("mkfifo", stdin_path)

      stdin_io = File.open(stdin_path, File::RDWR) # RDWR so the open never blocks
      log_io = File.open(log_path, "a")
      pid = Process.spawn(
        "bash", "-c", "cd #{(workdir || Dir.pwd).shellescape} && eval #{command.shellescape}",
        pgroup: true,
        in: stdin_io,
        out: log_io,
        err: [:child, :out],
      )
      log_io.close
      Process.detach(pid)
      @entries[session_id] = ProcessEntry.new(
        session_id: session_id, pid: pid, command: command,
        log_path: log_path, stdin_path: stdin_path, started_at: Time.now,
      )
      persist(session_id, notify: notify)
      @entries[session_id]
    end

    # Persisted tracking (timer model): each spawn records an entry so the
    # tick can detect exits across process invocations.
    def registry_path = File.join(@log_dir, "registry.json")

    def tracked
      return {} unless File.exist?(registry_path)

      JSON.parse(File.read(registry_path))
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def persist(session_id, notify: false, notified: false)
      entries = tracked
      e = @entries[session_id]
      entries[session_id] = {
        "session_id" => session_id, "pid" => e.pid, "command" => e.command,
        "log_path" => e.log_path, "started_at" => e.started_at.to_f,
        "notify" => notify, "notified" => notified,
      }
      tmp = "#{registry_path}.tmp"
      File.write(tmp, JSON.pretty_generate(entries))
      File.rename(tmp, registry_path)
    end

    def mark_notified(session_id)
      entries = tracked
      return unless entries[session_id]

      entries[session_id]["notified"] = true
      File.write("#{registry_path}.tmp", JSON.pretty_generate(entries))
      File.rename("#{registry_path}.tmp", registry_path)
    end

    # Tick check: yield each entry that armed notify, has exited, and hasn't
    # been notified yet. Caller formats + delivers the notification turn.
    def self.check_completions(log_dir:)
      reg = new(log_dir: log_dir)
      reg.tracked.each_value do |e|
        next unless e["notify"] && !e["notified"]

        alive = begin
          Process.kill(0, e["pid"])
          true
        rescue Errno::ESRCH
          false
        rescue Errno::EPERM
          true
        end
        next if alive

        exit_code = begin
          _pid, status = Process.wait2(e["pid"], Process::WNOHANG)
          status&.exitstatus
        rescue Errno::ECHILD
          nil
        end
        tail = File.exist?(e["log_path"]) ? File.read(e["log_path"])[-2_000..] : ""
        yield(e.merge("exit_code" => exit_code, "output_tail" => tail))
        reg.mark_notified(e["session_id"])
      end
    end

    def get(session_id) = @entries[session_id]

    def list
      @entries.values.map do |e|
        { session_id: e.session_id, pid: e.pid, command: e.command,
          status: e.alive? ? "running" : "exited", exit_code: e.exit_status,
          started_at: e.started_at.iso8601 }
      end
    end

    def poll(session_id)
      e = get(session_id) or return nil
      { session_id: session_id, status: e.alive? ? "running" : "exited", exit_code: e.exit_status }
    end

    def log(session_id, tail: nil)
      e = get(session_id) or return nil
      return "" unless File.exist?(e.log_path)

      content = File.read(e.log_path, encoding: Encoding::UTF_8)
      tail ? content.lines.last(tail).join : content
    end

    def wait_for(session_id, timeout: 60)
      e = get(session_id) or return nil
      deadline = Time.now + timeout
      sleep 0.1 while e.alive? && Time.now < deadline
      poll(session_id).merge(log: log(session_id))
    end

    def kill(session_id)
      e = get(session_id) or return nil
      Process.kill("TERM", -e.pid) # process group
      sleep 0.2
      Process.kill("KILL", -e.pid) if e.alive?
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    # Write data to the process's stdin FIFO (does not close).
    def write_stdin(session_id, data)
      e = get(session_id) or return nil
      File.open(e.stdin_path, File::WRONLY | File::NONBLOCK) { |f| f.write(data) }
      true
    rescue SystemCallError
      false
    end

    # Write + EOF (submit): the process sees the data then end-of-input.
    def submit_stdin(session_id, data)
      e = get(session_id) or return nil
      write_stdin(session_id, data)
      close_stdin(session_id)
      true
    end

    # EOF on stdin without new data.
    def close_stdin(session_id)
      e = get(session_id) or return nil
      # Re-opening and immediately closing a FIFO write end delivers EOF to
      # the reader once all writers close.
      File.open(e.stdin_path, File::WRONLY | File::NONBLOCK) { |f| }
      true
    rescue SystemCallError
      false
    end
  end
end
