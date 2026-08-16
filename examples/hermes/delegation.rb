# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

module Hermes
  # Delegation ledger + background runner — port of hermes-agent
  # tools/delegate_tool.py + async_delegation.py for the timer model.
  #
  # Background delegations are DETACHED CHILD PROCESSES (hermes' kanban-worker
  # pattern — the only shape that survives our process exit). The parent
  # records them in <dir>/delegations.json; the child runs a sub-agent and
  # writes <id>.result.json; the tick drains completions into a new turn.
  #
  # Caps: 3 concurrent, depth 1 (leaf default), 50 child iterations, 24k
  # summary ceiling.
  class Delegation
    MAX_CONCURRENT_CHILDREN = 3
    MAX_ITERATIONS = 50
    MAX_SUMMARY_CHARS = 24_000

    attr_reader :dir

    def initialize(dir: File.join(Dir.pwd, "delegations"))
      @dir = dir
      FileUtils.mkdir_p(@dir)
    end

    def ledger_path = File.join(@dir, "delegations.json")

    def records
      return {} unless File.exist?(ledger_path)

      JSON.parse(File.read(ledger_path))
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def save_records(records)
      tmp = "#{ledger_path}.tmp"
      File.write(tmp, JSON.pretty_generate(records))
      File.rename(tmp, ledger_path)
    end

    def running
      records.values.select { |r| r["status"] == "running" }
    end

    def capacity_available?
      running.size < MAX_CONCURRENT_CHILDREN
    end

    # Register + spawn a detached child. Returns the delegation id, or nil
    # when at capacity (hermes rejects, not queues).
    def dispatch(goal:, context:, role:, main_rb:, output_schema: nil)
      return nil unless capacity_available?

      id = "deleg_#{SecureRandom.hex(4)}"
      task = { "delegation_id" => id, "goal" => goal, "context" => context, "role" => role, "output_schema" => output_schema }
      task_path = File.join(@dir, "#{id}.task.json")
      File.write(task_path, JSON.pretty_generate(task))

      log_path = File.join(@dir, "#{id}.log")
      log_io = File.open(log_path, "a")
      pid = Process.spawn(RbConfig.ruby, main_rb, "--subagent", task_path,
                          chdir: Dir.pwd, out: log_io, err: [:child, :out])
      log_io.close
      Process.detach(pid)

      rec = records
      rec[id] = {
        "id" => id, "goal" => goal, "role" => role, "pid" => pid,
        "status" => "running", "dispatched_at" => Time.now.to_f,
        "task_path" => task_path, "log_path" => log_path,
        "delivered" => false,
      }
      save_records(rec)
      id
    end

    # Child side: write the result.
    def complete(id, status:, summary:, api_calls: 0, duration: 0.0, error: nil)
      summary = summary.to_s
      spill = nil
      if summary.length > MAX_SUMMARY_CHARS
        spill = File.join(@dir, "#{id}.summary.md")
        File.write(spill, summary)
        summary = "#{summary[0, MAX_SUMMARY_CHARS]}\n\n[summary truncated — full text at #{spill}]"
      end
      result = {
        "status" => status, "summary" => summary, "error" => error,
        "api_calls" => api_calls, "duration_seconds" => duration, "spill" => spill,
      }
      File.write(result_path(id), JSON.pretty_generate(result))

      rec = records
      rec[id]&.merge!("status" => status, "completed_at" => Time.now.to_f)
      save_records(rec)
      result
    end

    def result_path(id) = File.join(@dir, "#{id}.result.json")

    # Tick: completed-but-undelivered delegations with a result on disk.
    def completions
      records.values.select { |r| r["status"] != "running" && !r["delivered"] && File.exist?(result_path(r["id"])) }
    end

    def result_for(id)
      JSON.parse(File.read(result_path(id)))
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def mark_delivered(id)
      rec = records
      rec[id]&.merge!("delivered" => true)
      save_records(rec)
    end

    # Steer: a file the child reads at its next iteration boundary.
    def steer(id, message)
      File.write(File.join(@dir, "#{id}.steer"), message)
      true
    end

    def steer_for(id)
      path = File.join(@dir, "#{id}.steer")
      return nil unless File.exist?(path)

      File.read(path)
    ensure
      File.delete(path) if File.exist?(path)
    end

    def stop(id)
      pid = records.dig(id, "pid")
      return false unless pid

      Process.kill("TERM", -pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    # Per-iteration middleware for the child: drains the steer file into the
    # Steering queue at each iteration boundary.
    class SteerReader
      def initialize(app, delegation:, id:)
        @app = app
        @delegation = delegation
        @id = id
      end

      def call(env)
        text = @delegation.steer_for(@id)
        Hermes::Steering.steer(text) if text
        @app.call(env)
      end
    end
  end
end
